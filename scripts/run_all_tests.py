#!/usr/bin/env python3
"""
Scritchy Scratchy - Full CE Script Test Runner
Executes all CE Lua scripts via CE MCP Bridge Named Pipe and verifies results.
Output: analysis/live_test_results.txt
"""

import win32file
import win32pipe
import struct
import json
import time
import os
import sys
import argparse
from pathlib import Path
from typing import Optional, Dict, Any

ROOT_DIR = Path(__file__).resolve().parents[1]
PIPE_NAME = r"\\.\pipe\CE_MCP_Bridge_v99"  # must be r"\\.\..." (26 chars), NOT r"\.\..." (25)
SCRIPTS_DIR = str(ROOT_DIR / "ce_scripts")
OUTPUT_FILE = str(ROOT_DIR / "analysis" / "live_test_results.txt")

BASE_RVA_GACURRENT    = 0x4D02F0
BASE_RVA_SETTOKENS    = 0x4CFAA0
BASE_RVA_ADDMONEY     = 0x4C2580
BASE_RVA_ACTIVATEPERK = 0x4AE080
BASE_RVA_TRIGGERSJP   = 0x4B5930
BASE_RVA_SJP_PATCH    = 0x4B09EF   # patch_sjp_v3: je bytes
SJP_RDATA_RVA         = 0x29FCCD0  # sjp_max_chance writes 99999.0 here
TOKENS_OFFSET         = 0xC8


class CEClient:
    def __init__(self):
        self.handle = None
        self.req_id = 0

    def connect(self, timeout=5000) -> bool:
        try:
            win32pipe.WaitNamedPipe(PIPE_NAME, timeout)
            self.handle = win32file.CreateFile(
                PIPE_NAME,
                win32file.GENERIC_READ | win32file.GENERIC_WRITE,
                0, None,
                win32file.OPEN_EXISTING,
                0, None
            )
            return True
        except Exception as e:
            print(f"[connect] FAIL: {e}")
            return False

    def call(self, method: str, params: dict = None) -> dict:
        if params is None:
            params = {}
        self.req_id += 1
        req = {"jsonrpc": "2.0", "method": method, "params": params, "id": self.req_id}
        data = json.dumps(req).encode("utf-8")
        header = struct.pack("<I", len(data))
        win32file.WriteFile(self.handle, header + data)
        _, hdr = win32file.ReadFile(self.handle, 4)
        resp_len = struct.unpack("<I", hdr)[0]
        _, resp_data = win32file.ReadFile(self.handle, resp_len)
        return json.loads(resp_data.decode("utf-8"))

    def lua(self, code: str) -> dict:
        """Run Lua code, returns result dict with success/result/error."""
        r = self.call("evaluate_lua", {"code": code})
        return r.get("result", {})

    def read_double(self, addr: int) -> Optional[float]:
        code = f"local v = readDouble({addr}) return tostring(v)"
        r = self.lua(code)
        if r.get("success"):
            try:
                return float(r["result"])
            except Exception:
                return None
        return None

    def read_float(self, addr: int) -> Optional[float]:
        code = f"local v = readFloat({addr}) return tostring(v)"
        r = self.lua(code)
        if r.get("success"):
            try:
                return float(r["result"])
            except Exception:
                return None
        return None

    def read_bytes_hex(self, addr: int, count: int) -> Optional[str]:
        code = f"""
local b = readBytes({addr},{count},true)
if not b then return 'NIL' end
local parts={{}}
for i=1,#b do parts[#parts+1]=string.format('%02X',b[i]) end
return table.concat(parts,' ')
"""
        r = self.lua(code)
        if r.get("success"):
            return r.get("result")
        return None

    def get_module_base(self) -> Optional[int]:
        code = "local b = getAddressSafe('GameAssembly.dll') return string.format('0x%X',b or 0)"
        r = self.lua(code)
        if r.get("success"):
            try:
                return int(r["result"], 16)
            except Exception:
                return None
        return None

    def close(self):
        if self.handle:
            win32file.CloseHandle(self.handle)
            self.handle = None


def wrap_script(script_text: str) -> str:
    """Wrap a CE Lua script to capture print output and return it."""
    return r"""
local _captured = {}
local _orig_print = print
print = function(...)
  local parts = {}
  local args = {...}
  for i=1,select('#',...) do
    parts[#parts+1] = tostring(args[i] ~= nil and args[i] or 'nil')
  end
  local line = table.concat(parts, '\t')
  _captured[#_captured+1] = line
  _orig_print(line)
end
local _ok, _err = pcall(function()
""" + script_text + r"""
end)
print = _orig_print
if not _ok then
  _captured[#_captured+1] = '[PCALL_ERR] ' .. tostring(_err)
end
return table.concat(_captured, '\n')
"""


def run_script(client: CEClient, script_name: str) -> Dict[str, Any]:
    """Execute a .lua file and return result info."""
    path = os.path.join(SCRIPTS_DIR, script_name)
    if not os.path.exists(path):
        return {"script": script_name, "status": "FILE_NOT_FOUND", "output": ""}

    with open(path, "r", encoding="utf-8") as f:
        code = f.read()

    wrapped = wrap_script(code)

    t0 = time.time()
    r = client.lua(wrapped)
    elapsed = time.time() - t0

    ok = r.get("success", False)
    output = r.get("result", "") or ""
    error = r.get("error", "") or ""

    # Determine status from output
    if not ok:
        status = "CE_ERROR"
        if error:
            output = f"[CE_ERR] {error}\n{output}"
    elif "[PCALL_ERR]" in output:
        status = "LUA_ERROR"
    elif "ERROR:" in output.upper() and "OK:" not in output.upper():
        status = "SCRIPT_ERROR"
    elif "OK:" in output.upper() or "WARN:" in output.upper():
        status = "OK"
    else:
        status = "OK" if ok else "UNKNOWN"

    return {
        "script": script_name,
        "status": status,
        "output": output.strip(),
        "elapsed": f"{elapsed:.2f}s",
    }


def verify_tokens(client: CEClient, base: int) -> str:
    """Verify tokens value after tokens_set.lua"""
    # Get SaveData pointer first
    code = f"""
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base==0 then return 'BASE_FAIL' end
-- Try executeCodeEx stub to get SaveData.get_Current()
local stubName = 'ss_tokens_getcurrent_stub'
local stub = getAddressSafe(stubName)
if not stub or stub==0 then return 'STUB_NOT_FOUND' end
local ok,ptr = pcall(function() return executeCodeEx(0,5000,stub) end)
if not ok or not ptr or ptr==0 then return 'EXEC_FAIL' end
local tokens = readDouble(ptr + 0xC8)
return string.format('savedata=0x%X tokens=%.0f', ptr, tokens or -1)
"""
    r = client.lua(code)
    return r.get("result", "") if r.get("success") else "VERIFY_ERROR"


def verify_sjp_patch(client: CEClient, base: int) -> str:
    """Verify patch_sjp_v3 bytes at base+0x4B09EF"""
    addr = base + 0x4B09EF
    result = client.read_bytes_hex(addr, 6)
    expected = "0F 84 61 01 00 00"  # je patched back
    if result:
        match = "MATCH" if result.upper() == expected else f"MISMATCH(got={result})"
        return f"addr=0x{addr:X} bytes={result} {match}"
    return "READ_FAIL"


def verify_sjp_max(client: CEClient, base: int) -> str:
    """Verify sjp_max_chance wrote 99999.0 to .rdata"""
    addr = base + SJP_RDATA_RVA
    v = client.read_float(addr)
    if v is not None:
        match = "OK" if abs(v - 99999.0) < 1.0 else f"MISMATCH(val={v})"
        return f"addr=0x{addr:X} val={v} {match}"
    return "READ_FAIL"


SAFE_SCRIPTS = [
    "dump_pointer_chains.lua",
    "patch_sjp_v3.lua",
    "sjp_max_chance.lua",
    "force_symbols.lua",
]

DESTRUCTIVE_SCRIPTS = [
    "tokens_set_v2.lua",
    "money_add.lua",
    "perk_all_v2.lua",
    "trigger_sjp.lua",
    "prestige_unlock_v2.lua",
    "free_tickets.lua",
    "unlock_all_tickets_v2.lua",
    "rng_control_v2.lua",
]


def main():
    parser = argparse.ArgumentParser(description="Run Scritchy Scratchy CE Lua script tests")
    parser.add_argument(
        "--destructive",
        action="store_true",
        help="also run scripts that write game memory, patch code, or call game methods",
    )
    parser.add_argument(
        "--script",
        action="append",
        default=[],
        help="run one explicit script; repeatable; bypasses default script list",
    )
    args = parser.parse_args()

    print("=" * 65)
    print("Scritchy Scratchy - Full CE Script Test Runner")
    print("=" * 65)

    client = CEClient()
    if not client.connect():
        print("FATAL: Cannot connect to CE MCP Bridge pipe")
        sys.exit(1)
    print("Connected to CE MCP Bridge")

    # Get base address
    base = client.get_module_base()
    if not base or base == 0:
        print("WARN: GameAssembly.dll base not found, will try openProcess in scripts")
        base = 0
    else:
        print(f"GameAssembly.dll base: 0x{base:X}")

    if args.script:
        scripts = args.script
        mode = "explicit"
    elif args.destructive:
        scripts = SAFE_SCRIPTS + DESTRUCTIVE_SCRIPTS
        mode = "destructive"
    else:
        scripts = SAFE_SCRIPTS
        mode = "safe"

    print(f"Test mode: {mode}")

    results = []

    for script in scripts:
        print(f"\n[TEST] {script}...")
        r = run_script(client, script)
        results.append(r)
        print(f"  status={r['status']} ({r['elapsed']})")
        if r["output"]:
            for line in r["output"].split("\n")[:5]:
                print(f"  > {line}")

    # Post-run memory verifications
    print("\n[VERIFY] Memory checks...")
    verifications = []

    if base != 0:
        v1 = verify_sjp_patch(client, base)
        print(f"  patch_sjp_v3: {v1}")
        verifications.append(f"patch_sjp_v3: {v1}")

        v2 = verify_sjp_max(client, base)
        print(f"  sjp_max_chance: {v2}")
        verifications.append(f"sjp_max_chance: {v2}")

        v3 = verify_tokens(client, base)
        print(f"  tokens: {v3}")
        verifications.append(f"tokens: {v3}")

    # Write output file
    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    lines = []
    lines.append("=" * 65)
    lines.append("Scritchy Scratchy - Live CE Test Results")
    lines.append(f"Run time: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"Mode: {mode}")
    lines.append(f"GameAssembly base: 0x{base:X}" if base else "GameAssembly base: NOT FOUND")
    lines.append("=" * 65)
    lines.append("")

    ok_count = 0
    fail_count = 0
    for r in results:
        status = r["status"]
        marker = "OK  " if status in ("OK",) else "FAIL"
        if status == "OK":
            ok_count += 1
        else:
            fail_count += 1
        lines.append(f"[{marker}] {r['script']} ({r['elapsed']})")
        if r["output"]:
            for line in r["output"].split("\n"):
                lines.append(f"      {line}")
        lines.append("")

    lines.append("-" * 65)
    lines.append("MEMORY VERIFICATIONS:")
    for v in verifications:
        lines.append(f"  {v}")

    lines.append("")
    lines.append(f"SUMMARY: {ok_count} OK / {fail_count} FAIL / {len(scripts)} total")

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nResults written to: {OUTPUT_FILE}")
    print(f"SUMMARY: {ok_count} OK / {fail_count} FAIL / {len(scripts)} total")

    client.close()
    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
