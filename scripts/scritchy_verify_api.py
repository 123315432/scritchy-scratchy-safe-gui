#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import queue
import re
import struct
import threading
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

import win32file
import win32pipe

ROOT_DIR = Path(__file__).resolve().parents[1]
SAFE_SUITE = ROOT_DIR / "ce_scripts" / "scritchy_safe_suite.lua"
REPORT_DIR = ROOT_DIR / "analysis"
REPORT_PATH = REPORT_DIR / "gui_function_verify_report.json"
PIPE_NAME = r"\\.\pipe\CE_MCP_Bridge_v99"
GAME_EXE = "ScritchyScratchy.exe"


@dataclass
class VerifyResult:
    name: str
    ok: bool
    duration_sec: float
    summary: str
    raw: str = ""
    error: str = ""


def pipe_probe(timeout_ms: int = 250) -> tuple[bool, str]:
    try:
        win32pipe.WaitNamedPipe(PIPE_NAME, timeout_ms)
        return True, "available"
    except Exception as exc:
        code = getattr(exc, "winerror", None)
        if code is None and getattr(exc, "args", None):
            code = exc.args[0]
        if code == 121:
            return False, "busy_or_single_client_pipe"
        if code == 2:
            return False, "pipe_not_found"
        return False, repr(exc)


class CEClient:
    def __init__(self):
        self.handle = None
        self.req_id = 0
        self.lock = threading.RLock()

    def connect(self, timeout_ms: int = 8000):
        with self.lock:
            if self.handle:
                return
            deadline = time.time() + timeout_ms / 1000.0
            reason = "timeout"
            while time.time() < deadline:
                ok, reason = pipe_probe(250)
                if ok:
                    break
                time.sleep(0.15)
            if not ok:
                raise RuntimeError(f"CE pipe unavailable: {reason}")
            self.handle = win32file.CreateFile(
                PIPE_NAME,
                win32file.GENERIC_READ | win32file.GENERIC_WRITE,
                0,
                None,
                win32file.OPEN_EXISTING,
                0,
                None,
            )

    def close(self):
        with self.lock:
            handle = self.handle
            self.handle = None
        if handle:
            try:
                win32file.CloseHandle(handle)
            except Exception as exc:
                code = getattr(exc, "winerror", None)
                if code is None and getattr(exc, "args", None):
                    code = exc.args[0]
                if code != 6:
                    raise

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        with self.lock:
            self.connect()
            self.req_id += 1
            req = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": self.req_id}
            body = json.dumps(req).encode("utf-8")
            win32file.WriteFile(self.handle, struct.pack("<I", len(body)) + body)
            _, hdr = win32file.ReadFile(self.handle, 4)
            size = struct.unpack("<I", hdr)[0]
            _, data = win32file.ReadFile(self.handle, size)
            return json.loads(data.decode("utf-8"))

    def lua(self, code: str) -> dict[str, Any]:
        return self.call("evaluate_lua", {"code": code}).get("result", {})


def lua_quote(text: str) -> str:
    return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"


def suite_lua(action: str, extra: str = "") -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return f"openProcess('{GAME_EXE}')\n{extra}\nSCRITCHY_SAFE_ACTION={lua_quote(action)}\nlocal ok,res=pcall(dofile,{lua_quote(path)})\nreturn tostring(ok)..' :: '..tostring(res)"


READY_LUA = f"""
openProcess('{GAME_EXE}')
local pid = getOpenedProcessID and getOpenedProcessID() or 0
local base = getAddressSafe('GameAssembly.dll')
if not pid or pid == 0 then return 'WAIT pid nil' end
if not base or base == 0 then return 'WAIT GameAssembly nil pid=' .. tostring(pid) end
pcall(LaunchMonoDataCollector)
local cls = mono_findClass and mono_findClass('', 'SaveData')
if not cls then return 'WAIT SaveData_class nil pid=' .. tostring(pid) end
local saddr = mono_class_getStaticFieldAddress(0, cls)
if not saddr or saddr == 0 then return 'WAIT SaveData_static nil pid=' .. tostring(pid) end
for _, f in ipairs(mono_class_enumFields(cls, true) or {{}}) do
  if f.name == '_current' or f.name == 'current' then
    local p = readQword(saddr + f.offset)
    if p and p ~= 0 then
      local layer = readQword(p + 0x30)
      if layer and layer ~= 0 then
        return string.format('READY pid=%s SaveData=0x%X LayerOne=0x%X source=mono_static', tostring(pid), p, layer)
      end
      return string.format('WAIT LayerOne nil pid=%s SaveData=0x%X', tostring(pid), p)
    end
  end
end
return 'WAIT SaveData_current nil pid=' .. tostring(pid)
"""


def wait_game_ready(client: CEClient, timeout_sec: int, quiet: bool = False) -> str:
    deadline = time.time() + timeout_sec
    last = ""
    while time.time() < deadline:
        try:
            res = client.lua(READY_LUA)
            if not res.get("success", False):
                last = str(res)
            else:
                last = str(res.get("result", ""))
                if last.startswith("READY "):
                    if not quiet:
                        print(last, flush=True)
                    return last
        except Exception as exc:
            last = repr(exc)
        if not quiet:
            print(f"waiting game ready: {last}", flush=True)
        time.sleep(2.0)
    raise TimeoutError(f"game not ready after {timeout_sec}s: {last}")


def symbol_write_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "local function chanceValue(text, side)",
        "  for line in tostring(text):gmatch('[^\\n]+') do",
        "    local before, after = line:match('Lucky Cat / Fishbone[^\\n]- ([%d%.,%-eE]+) %-> ([%d%.,%-eE]+) changed=')",
        "    if before then",
        "      local values = side == 'after' and after or before",
        "      local first = values:match('^([^,]+)')",
        "      return tonumber(first)",
        "    end",
        "  end",
        "  return nil",
        "end",
        "SCRITCHY_SAFE_ACTION='symbol_apply'",
        "SCRITCHY_SYMBOL_TICKET='Lucky Cat'",
        "SCRITCHY_SYMBOL_ID='Fishbone'",
        "SCRITCHY_SYMBOL_VALUE=0",
        "SCRITCHY_SYMBOL_LUCK_INDEX=0",
        "SCRITCHY_SYMBOL_DRYRUN=true",
        f"local ok0,res0=pcall(dofile,{lua_quote(path)})",
        "if not ok0 then return 'ERR: dryrun failed ' .. tostring(res0) end",
        "local original = chanceValue(res0, 'after')",
        "if not original then return 'ERR: cannot parse Fishbone original from dryrun: ' .. tostring(res0) end",
        "local testValue = original + 1",
        "if math.abs(testValue - original) < 0.001 then testValue = original + 10 end",
        "SCRITCHY_SAFE_ACTION='symbol_apply'",
        "SCRITCHY_SYMBOL_TICKET='Lucky Cat'",
        "SCRITCHY_SYMBOL_ID='Fishbone'",
        "SCRITCHY_SYMBOL_VALUE=testValue",
        "SCRITCHY_SYMBOL_LUCK_INDEX=0",
        "SCRITCHY_SYMBOL_DRYRUN=false",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local changedValue = chanceValue(res1, 'after')",
        "SCRITCHY_SAFE_ACTION='symbol_apply'",
        "SCRITCHY_SYMBOL_TICKET='Lucky Cat'",
        "SCRITCHY_SYMBOL_ID='Fishbone'",
        "SCRITCHY_SYMBOL_VALUE=original",
        "SCRITCHY_SYMBOL_LUCK_INDEX=0",
        "SCRITCHY_SYMBOL_DRYRUN=false",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local restoredValue = chanceValue(res2, 'after')",
        "local changed = ok1 and changedValue and math.abs(changedValue - testValue) < 0.01",
        "local restored = ok2 and restoredValue and math.abs(restoredValue - original) < 0.01",
        "return tostring(ok1)..' :: '..tostring(res1)..'\\nRESTORE '..tostring(ok2)..' :: '..tostring(res2)..string.format('\\noriginal=%s changedValue=%s restoredValue=%s changed=%s restored=%s', tostring(original), tostring(changedValue), tostring(restoredValue), tostring(changed), tostring(restored))",
    ])


def symbol_type_dryrun_lua() -> str:
    return suite_lua(
        "symbol_apply",
        "SCRITCHY_SYMBOL_TICKET='Lucky Cat'\n"
        "SCRITCHY_SYMBOL_TYPE=1\n"
        "SCRITCHY_SYMBOL_VALUE=99999\n"
        "SCRITCHY_SYMBOL_LUCK_INDEX=0\n"
        "SCRITCHY_SYMBOL_DRYRUN=true",
    )


def rng_patch_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "SCRITCHY_SAFE_ACTION='rng_enable'",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "SCRITCHY_SAFE_ACTION='rng_disable'",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local changed = ok1 and tostring(res1):find('OK') ~= nil",
        "local restored = ok2 and tostring(res2):find('UNINSTALL OK') ~= nil",
        "return string.format('rng patch restore changed=%s restored=%s\\nENABLE %s\\nDISABLE %s', tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def free_patch_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "SCRITCHY_SAFE_ACTION='free_enable'",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "SCRITCHY_SAFE_ACTION='free_disable'",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local t1=tostring(res1)",
        "local t2=tostring(res2)",
        "local changed = ok1 and t1:find('mode=ENABLE patched=', 1, true) ~= nil and t1:find('PATCHED', 1, true) ~= nil and t1:find('ERR', 1, true) == nil and t1:find('READ_FAIL', 1, true) == nil",
        "local restored = ok2 and t2:find('mode=RESTORE', 1, true) ~= nil and t2:find('RESTORED', 1, true) ~= nil and t2:find('ERR', 1, true) == nil",
        "return string.format('free patch restore changed=%s restored=%s\\nENABLE %s\\nDISABLE %s', tostring(changed), tostring(restored), t1, t2)",
    ])


def custom_save_fields_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function hx(v) return v and string.format('0x%X', v) or 'nil' end",
        "local function closeEnough(a,b) return a and b and math.abs(a-b) <= 0.0001 * math.max(1, math.abs(b)) end",
        "local function getSaveData()",
        "  local cls = mono_findClass and mono_findClass('', 'SaveData')",
        "  if not cls then return nil, 'class_not_found' end",
        "  local saddr = mono_class_getStaticFieldAddress(0, cls)",
        "  if not saddr or saddr == 0 then return nil, 'static_not_found' end",
        "  for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do",
        "    if f.name == '_current' or f.name == 'current' then",
        "      local p = readQword(saddr + f.offset)",
        "      if p and p ~= 0 then return p, 'mono_static' end",
        "    end",
        "  end",
        "  return nil, 'current_nil'",
        "end",
        "local saveData, source = getSaveData()",
        "if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end",
        "local layerOne = readQword(saveData + 0x30)",
        "if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData=' .. hx(saveData) end",
        "local money0 = readDouble(layerOne + 0x10)",
        "local tokens0 = readDouble(saveData + 0xC8)",
        "local souls0 = readInteger(layerOne + 0x88, 4)",
        "local prestigeCurrency0 = readInteger(saveData + 0x3C, 4)",
        "local prestigeCount0 = readInteger(saveData + 0x38, 4)",
        "local act0 = readInteger(saveData + 0x40, 4)",
        "if not money0 or not tokens0 or not souls0 or not prestigeCurrency0 or not prestigeCount0 or not act0 then return 'ERR: read custom fields failed money=' .. tostring(money0) .. ' tokens=' .. tostring(tokens0) .. ' souls=' .. tostring(souls0) .. ' prestigeCurrency=' .. tostring(prestigeCurrency0) .. ' prestigeCount=' .. tostring(prestigeCount0) .. ' act=' .. tostring(act0) end",
        "local moneyTest = 12345.5",
        "if closeEnough(money0, moneyTest) then moneyTest = 23456.5 end",
        "local tokensTest = 123456.0",
        "if closeEnough(tokens0, tokensTest) then tokensTest = 654321.0 end",
        "local function intTest(before, fallback, maxv)",
        "  local target = fallback",
        "  if before == target then target = target + 1 end",
        "  if target > maxv then target = before - 1 end",
        "  if target < 0 then target = 0 end",
        "  return target",
        "end",
        "local soulsTest = intTest(souls0, 1234, 2147483647)",
        "local prestigeCurrencyTest = intTest(prestigeCurrency0, 2345, 2147483647)",
        "local prestigeCountTest = intTest(prestigeCount0, 12, 999999)",
        "local actTest = intTest(act0, 3, 99)",
        "SCRITCHY_SAFE_ACTION='custom_save_fields'",
        "SCRITCHY_CUSTOM_MONEY=moneyTest",
        "SCRITCHY_CUSTOM_TOKENS=tokensTest",
        "SCRITCHY_CUSTOM_SOULS=soulsTest",
        "SCRITCHY_CUSTOM_PRESTIGE_CURRENCY=prestigeCurrencyTest",
        "SCRITCHY_CUSTOM_PRESTIGE_COUNT=prestigeCountTest",
        "SCRITCHY_CUSTOM_ACT=actTest",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local money1 = readDouble(layerOne + 0x10)",
        "local tokens1 = readDouble(saveData + 0xC8)",
        "local souls1 = readInteger(layerOne + 0x88, 4)",
        "local prestigeCurrency1 = readInteger(saveData + 0x3C, 4)",
        "local prestigeCount1 = readInteger(saveData + 0x38, 4)",
        "local act1 = readInteger(saveData + 0x40, 4)",
        "SCRITCHY_SAFE_ACTION='custom_save_fields'",
        "SCRITCHY_CUSTOM_MONEY=money0",
        "SCRITCHY_CUSTOM_TOKENS=tokens0",
        "SCRITCHY_CUSTOM_SOULS=souls0",
        "SCRITCHY_CUSTOM_PRESTIGE_CURRENCY=prestigeCurrency0",
        "SCRITCHY_CUSTOM_PRESTIGE_COUNT=prestigeCount0",
        "SCRITCHY_CUSTOM_ACT=act0",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local money2 = readDouble(layerOne + 0x10)",
        "local tokens2 = readDouble(saveData + 0xC8)",
        "local souls2 = readInteger(layerOne + 0x88, 4)",
        "local prestigeCurrency2 = readInteger(saveData + 0x3C, 4)",
        "local prestigeCount2 = readInteger(saveData + 0x38, 4)",
        "local act2 = readInteger(saveData + 0x40, 4)",
        "local changed = ok1 and closeEnough(money1, moneyTest) and closeEnough(tokens1, tokensTest) and souls1 == soulsTest and prestigeCurrency1 == prestigeCurrencyTest and prestigeCount1 == prestigeCountTest and act1 == actTest",
        "local restored = ok2 and closeEnough(money2, money0) and closeEnough(tokens2, tokens0) and souls2 == souls0 and prestigeCurrency2 == prestigeCurrency0 and prestigeCount2 == prestigeCount0 and act2 == act0",
        "return string.format('custom save restore ok1=%s ok2=%s source=%s money %.6g -> %.6g -> %.6g tokens %.6g -> %.6g -> %.6g souls %s -> %s -> %s prestigeCurrency %s -> %s -> %s prestigeCount %s -> %s -> %s act %s -> %s -> %s changed=%s restored=%s\\nAPPLY %s\\nRESTORE %s', tostring(ok1), tostring(ok2), tostring(source), money0, money1, money2, tokens0, tokens1, tokens2, tostring(souls0), tostring(souls1), tostring(souls2), tostring(prestigeCurrency0), tostring(prestigeCurrency1), tostring(prestigeCurrency2), tostring(prestigeCount0), tostring(prestigeCount1), tostring(prestigeCount2), tostring(act0), tostring(act1), tostring(act2), tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def scratch_runtime_dispatcher_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function findInstance(className)",
        "  local cls = mono_findClass and mono_findClass('', className)",
        "  if not cls then return nil, 'class_not_found_' .. className end",
        "  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}",
        "  if list[1] and list[1] ~= 0 then return list[1], 'mono_instance' end",
        "  return nil, 'instance_not_found_' .. className",
        "end",
        "local scratching, source = findInstance('PlayerScratching')",
        "if not scratching or scratching == 0 then return 'ERR: PlayerScratching nil source=' .. tostring(source) end",
        "local tool = readQword(scratching + 0x28)",
        "if not tool or tool == 0 then return 'ERR: ScratchTool nil' end",
        "local fields = {",
        "  {name='scratchParticleSpeed', global='SCRITCHY_SCRATCH_PARTICLE_SPEED', ptr=scratching, off=0x3C, kind='float', lo=0.1, hi=10000},",
        "  {name='mouseVelocityMax', global='SCRITCHY_MOUSE_VELOCITY_MAX', ptr=scratching, off=0x48, kind='float', lo=0.1, hi=100000},",
        "  {name='scratchChecksPerSecond', global='SCRITCHY_SCRATCH_CHECKS_PER_SECOND', ptr=scratching, off=0x4C, kind='int', lo=1, hi=240},",
        "  {name='scratchLuck', global='SCRITCHY_SCRATCH_LUCK', ptr=scratching, off=0x94, kind='int', lo=-100000, hi=100000},",
        "  {name='luckReduction', global='SCRITCHY_LUCK_REDUCTION', ptr=scratching, off=0x98, kind='int', lo=-100000, hi=100000},",
        "  {name='toolStrength', global='SCRITCHY_TOOL_STRENGTH', ptr=tool, off=0x28, kind='int', lo=0, hi=100000},",
        "  {name='toolSizeBacking', global='SCRITCHY_TOOL_SIZE', ptr=tool, off=0x30, kind='int', lo=0, hi=100000},",
        "  {name='toolSizeReduction', global='SCRITCHY_TOOL_SIZE_REDUCTION', ptr=tool, off=0x34, kind='int', lo=-100000, hi=100000},",
        "}",
        "local function closeEnough(a,b) return a and b and math.abs(a-b) <= 0.0001 * math.max(1, math.abs(b)) end",
        "local function readField(f) return f.kind == 'int' and readInteger(f.ptr + f.off, 4) or readFloat(f.ptr + f.off) end",
        "local active = {}",
        "for _, f in ipairs(fields) do",
        "  local before = readField(f)",
        "  if before == nil then return 'ERR: read scratch field failed ' .. f.name end",
        "  local test = before + 1",
        "  if test > f.hi then test = before - 1 end",
        "  if test < f.lo then test = f.lo end",
        "  if f.kind == 'int' then test = math.floor(test); if test == before then test = math.min(f.hi, before + 1) end end",
        "  active[#active+1] = {field=f, before=before, test=test}",
        "  _G[f.global] = test",
        "end",
        "SCRITCHY_SAFE_ACTION='scratch_apply'",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local changed = ok1",
        "for _, item in ipairs(active) do",
        "  local value = readField(item.field)",
        "  item.changed = value",
        "  if item.field.kind == 'int' then",
        "    if value ~= item.test then changed = false end",
        "  elseif not closeEnough(value, item.test) then changed = false end",
        "  _G[item.field.global] = item.before",
        "end",
        "SCRITCHY_SAFE_ACTION='scratch_apply'",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local restored = ok2",
        "local parts = {}",
        "for _, item in ipairs(active) do",
        "  local value = readField(item.field)",
        "  item.restored = value",
        "  if item.field.kind == 'int' then",
        "    if value ~= item.before then restored = false end",
        "  elseif not closeEnough(value, item.before) then restored = false end",
        "  parts[#parts+1] = string.format('%s %s -> %s -> %s', item.field.name, tostring(item.before), tostring(item.changed), tostring(item.restored))",
        "  _G[item.field.global] = nil",
        "end",
        "return string.format('scratch runtime restore ok1=%s ok2=%s source=%s fields=%d %s changed=%s restored=%s\\nAPPLY %s\\nRESTORE %s', tostring(ok1), tostring(ok2), tostring(source), #active, table.concat(parts, ' | '), tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def upgrade_dispatcher_restore_lua(action: str, target_names: list[str], globals_by_name: dict[str, str], max_counts: dict[str, int] | None = None) -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    names_lua = "{" + ",".join(lua_quote(name) for name in target_names) + "}"
    globals_lua = "{" + ",".join(f"[{lua_quote(name)}]={lua_quote(globals_by_name[name])}" for name in target_names) + "}"
    max_source = {
        "Scratch Bot": 1,
        "Scratch Bot Speed": 30,
        "Scratch Bot Capacity": 10,
        "Scratch Bot Strength": 20,
        "Subscription Bot": 1,
        "Buying Speed": 10,
    }
    if max_counts:
        max_source.update(max_counts)
    max_lua = "{" + ",".join(f"[{lua_quote(name)}]={int(value)}" for name, value in max_source.items()) + "}"
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        f"local ACTION={lua_quote(action)}",
        f"local TARGET_NAMES={names_lua}",
        f"local GLOBALS={globals_lua}",
        f"local MAX_COUNTS={max_lua}",
        "local function hx(v) return v and string.format('0x%X', v) or 'nil' end",
        "local function rstr(p) if not p or p == 0 then return nil end return readString(p + 0x14, 256, true) end",
        "local function getSaveData()",
        "  local cls = mono_findClass and mono_findClass('', 'SaveData')",
        "  if not cls then return nil, 'class_not_found' end",
        "  local saddr = mono_class_getStaticFieldAddress(0, cls)",
        "  if not saddr or saddr == 0 then return nil, 'static_not_found' end",
        "  for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do",
        "    if f.name == '_current' or f.name == 'current' then",
        "      local p = readQword(saddr + f.offset)",
        "      if p and p ~= 0 then return p, 'mono_static' end",
        "    end",
        "  end",
        "  return nil, 'current_nil'",
        "end",
        "local function readCounts()",
        "  local saveData, source = getSaveData()",
        "  if not saveData or saveData == 0 then return nil, 'SaveData nil source=' .. tostring(source) end",
        "  local layerOne = readQword(saveData + 0x30)",
        "  if not layerOne or layerOne == 0 then return nil, 'layerOne nil saveData=' .. hx(saveData) end",
        "  local dict = readQword(layerOne + 0x28)",
        "  local entries = dict and readQword(dict + 0x18) or nil",
        "  if not entries or entries == 0 then return nil, 'upgradeDataDict entries nil dict=' .. hx(dict) end",
        "  local arrlen = readInteger(entries + 0x18) or 0",
        "  local counts = {}",
        "  for i=0,arrlen-1 do",
        "    local e = entries + 0x20 + i * 24",
        "    local hash = readInteger(e)",
        "    local key = readQword(e + 8)",
        "    local val = readQword(e + 16)",
        "    local name = rstr(key)",
        "    if hash and hash >= 0 and val and val ~= 0 and GLOBALS[name] then counts[name] = readInteger(val + 0x18, 4) end",
        "  end",
        "  return counts, tostring(source)",
        "end",
        "local before, source = readCounts()",
        "if not before then return 'ERR: ' .. tostring(source) end",
        "local tests = {}",
        "for _, name in ipairs(TARGET_NAMES) do",
        "  local current = before[name]",
        "  if current == nil then return 'ERR: missing upgrade ' .. name end",
        "  local maxv = MAX_COUNTS[name] or current",
        "  local test = current > 0 and current - 1 or math.min(maxv, 1)",
        "  if test == current then test = math.max(0, current - 1) end",
        "  tests[name] = test",
        "  _G[GLOBALS[name]] = test",
        "end",
        "SCRITCHY_SAFE_ACTION=ACTION",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local changedCounts = readCounts()",
        "for _, name in ipairs(TARGET_NAMES) do _G[GLOBALS[name]] = before[name] end",
        "SCRITCHY_SAFE_ACTION=ACTION",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local restoredCounts = readCounts()",
        "local changed, restored = ok1 and changedCounts ~= nil, ok2 and restoredCounts ~= nil",
        "local parts = {}",
        "for _, name in ipairs(TARGET_NAMES) do",
        "  if not changedCounts or changedCounts[name] ~= tests[name] then changed = false end",
        "  if not restoredCounts or restoredCounts[name] ~= before[name] then restored = false end",
        "  parts[#parts+1] = string.format('%s %s -> %s -> %s', name, tostring(before[name]), tostring(changedCounts and changedCounts[name]), tostring(restoredCounts and restoredCounts[name]))",
        "  _G[GLOBALS[name]] = nil",
        "end",
        "return string.format('upgrade restore action=%s source=%s %s changed=%s restored=%s\\nAPPLY %s\\nRESTORE %s', ACTION, tostring(source), table.concat(parts, ' | '), tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def subscription_runtime_write_restore_lua() -> str:
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function hx(v) return v and string.format('0x%X', v) or 'nil' end",
        "local function closeEnough(a,b) return a and b and math.abs(a-b) <= 0.0001 * math.max(1, math.abs(b)) end",
        "local function findInstance(className)",
        "  local cached = rawget(_G, 'SCRITCHY_CACHED_' .. className)",
        "  if cached and cached ~= 0 then",
        "    local ok = pcall(function() readQword(cached) end)",
        "    if ok then return cached, 'cache' end",
        "    rawset(_G, 'SCRITCHY_CACHED_' .. className, nil)",
        "  end",
        "  local cls = mono_findClass and mono_findClass('', className)",
        "  if not cls then return nil, 'class_not_found_' .. className end",
        "  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}",
        "  if list[1] and list[1] ~= 0 then rawset(_G, 'SCRITCHY_CACHED_' .. className, list[1]); return list[1], 'mono_instance' end",
        "  return nil, 'instance_not_found_' .. className",
        "end",
        "local bot, source = findInstance('SubscriptionBot')",
        "if not bot or bot == 0 then return 'ERR: SubscriptionBot nil source=' .. tostring(source) end",
        "local duration0 = readFloat(bot + 0x28)",
        "local max0 = readInteger(bot + 0x48, 4)",
        "local paused0 = readBytes(bot + 0x58, 1, false)",
        "local speed0 = readFloat(bot + 0x60)",
        "if not duration0 or not max0 or not paused0 or not speed0 then return 'ERR: read failed duration=' .. tostring(duration0) .. ' max=' .. tostring(max0) .. ' paused=' .. tostring(paused0) .. ' speed=' .. tostring(speed0) end",
        "local durationTest = duration0 + 0.25",
        "if durationTest > 3600 then durationTest = math.max(0.01, duration0 - 0.25) end",
        "local maxTest = max0 + 1",
        "if maxTest > 100000 then maxTest = max0 - 1 end",
        "if maxTest < 0 then maxTest = 1 end",
        "local pausedTest = paused0 == 1 and 0 or 1",
        "local speedTest = speed0 + 1",
        "if speedTest > 100000 then speedTest = math.max(0.01, speed0 - 1) end",
        "if speedTest < 0.01 then speedTest = 1 end",
        "writeFloat(bot + 0x28, durationTest)",
        "writeInteger(bot + 0x48, math.floor(maxTest))",
        "writeBytes(bot + 0x58, pausedTest)",
        "writeFloat(bot + 0x60, speedTest)",
        "local duration1 = readFloat(bot + 0x28)",
        "local max1 = readInteger(bot + 0x48, 4)",
        "local paused1 = readBytes(bot + 0x58, 1, false)",
        "local speed1 = readFloat(bot + 0x60)",
        "writeFloat(bot + 0x28, duration0)",
        "writeInteger(bot + 0x48, max0)",
        "writeBytes(bot + 0x58, paused0)",
        "writeFloat(bot + 0x60, speed0)",
        "local duration2 = readFloat(bot + 0x28)",
        "local max2 = readInteger(bot + 0x48, 4)",
        "local paused2 = readBytes(bot + 0x58, 1, false)",
        "local speed2 = readFloat(bot + 0x60)",
        "local changed = closeEnough(duration1, durationTest) and (max1 == math.floor(maxTest)) and paused1 == pausedTest and closeEnough(speed1, speedTest)",
        "local restored = closeEnough(duration2, duration0) and (max2 == max0) and paused2 == paused0 and closeEnough(speed2, speed0)",
        "return string.format('subscription runtime restore bot=%s source=%s processingDuration %.6g -> %.6g -> %.6g maxTicketCount %s -> %s -> %s paused %s -> %s -> %s ProcessingSpeedMult %.6g -> %.6g -> %.6g changed=%s restored=%s', hx(bot), tostring(source), duration0, duration1, duration2, tostring(max0), tostring(max1), tostring(max2), tostring(paused0), tostring(paused1), tostring(paused2), speed0, speed1, speed2, tostring(changed), tostring(restored))",
    ])


def subscription_runtime_dispatcher_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function closeEnough(a,b) return a and b and math.abs(a-b) <= 0.0001 * math.max(1, math.abs(b)) end",
        "local function findInstance(className)",
        "  local cached = rawget(_G, 'SCRITCHY_CACHED_' .. className)",
        "  if cached and cached ~= 0 then",
        "    local ok = pcall(function() readQword(cached) end)",
        "    if ok then return cached, 'cache' end",
        "    rawset(_G, 'SCRITCHY_CACHED_' .. className, nil)",
        "  end",
        "  local cls = mono_findClass and mono_findClass('', className)",
        "  if not cls then return nil, 'class_not_found_' .. className end",
        "  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}",
        "  if list[1] and list[1] ~= 0 then rawset(_G, 'SCRITCHY_CACHED_' .. className, list[1]); return list[1], 'mono_instance' end",
        "  return nil, 'instance_not_found_' .. className",
        "end",
        "local bot, source = findInstance('SubscriptionBot')",
        "if not bot or bot == 0 then return 'ERR: SubscriptionBot nil source=' .. tostring(source) end",
        "local duration0 = readFloat(bot + 0x28)",
        "local max0 = readInteger(bot + 0x48, 4)",
        "local paused0 = readBytes(bot + 0x58, 1, false)",
        "local speed0 = readFloat(bot + 0x60)",
        "if not duration0 or not max0 or not paused0 or not speed0 then return 'ERR: read failed duration=' .. tostring(duration0) .. ' max=' .. tostring(max0) .. ' paused=' .. tostring(paused0) .. ' speed=' .. tostring(speed0) end",
        "local durationTest = duration0 + 0.25",
        "if durationTest > 3600 then durationTest = math.max(0.01, duration0 - 0.25) end",
        "local maxTest = max0 + 1",
        "if maxTest > 100000 then maxTest = max0 - 1 end",
        "if maxTest < 0 then maxTest = 1 end",
        "local pausedTest = paused0 == 1 and 0 or 1",
        "local speedTest = speed0 + 1",
        "if speedTest > 100000 then speedTest = math.max(0.01, speed0 - 1) end",
        "if speedTest < 0.01 then speedTest = 1 end",
        "SCRITCHY_SAFE_ACTION='subscription_runtime_apply'",
        "SCRITCHY_SUB_PROCESSING_DURATION=durationTest",
        "SCRITCHY_SUB_MAX_TICKET_COUNT=maxTest",
        "SCRITCHY_SUB_PAUSED=pausedTest",
        "SCRITCHY_SUB_PROCESSING_SPEED_MULT=speedTest",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local duration1 = readFloat(bot + 0x28)",
        "local max1 = readInteger(bot + 0x48, 4)",
        "local paused1 = readBytes(bot + 0x58, 1, false)",
        "local speed1 = readFloat(bot + 0x60)",
        "SCRITCHY_SAFE_ACTION='subscription_runtime_apply'",
        "SCRITCHY_SUB_PROCESSING_DURATION=duration0",
        "SCRITCHY_SUB_MAX_TICKET_COUNT=max0",
        "SCRITCHY_SUB_PAUSED=paused0",
        "SCRITCHY_SUB_PROCESSING_SPEED_MULT=speed0",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local duration2 = readFloat(bot + 0x28)",
        "local max2 = readInteger(bot + 0x48, 4)",
        "local paused2 = readBytes(bot + 0x58, 1, false)",
        "local speed2 = readFloat(bot + 0x60)",
        "local changed = ok1 and closeEnough(duration1, durationTest) and (max1 == math.floor(maxTest)) and paused1 == pausedTest and closeEnough(speed1, speedTest)",
        "local restored = ok2 and closeEnough(duration2, duration0) and (max2 == max0) and paused2 == paused0 and closeEnough(speed2, speed0)",
        "return string.format('dispatcher_restore ok1=%s ok2=%s source=%s processingDuration %.6g -> %.6g -> %.6g maxTicketCount %s -> %s -> %s paused %s -> %s -> %s ProcessingSpeedMult %.6g -> %.6g -> %.6g changed=%s restored=%s\\nAPPLY %s\\nRESTORE %s', tostring(ok1), tostring(ok2), tostring(source), duration0, duration1, duration2, tostring(max0), tostring(max1), tostring(max2), tostring(paused0), tostring(paused1), tostring(paused2), speed0, speed1, speed2, tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def gadget_runtime_dispatcher_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    fields = [
        ("EggTimer", "BatteryCapacityMult", "SCRITCHY_EGGTIMER_BATTERY_CAPACITY_MULT", 0x40, "float", 0.01, 100000),
        ("EggTimer", "BatteryChargeMult", "SCRITCHY_EGGTIMER_BATTERY_CHARGE_MULT", 0x44, "float", 0.01, 100000),
        ("EggTimer", "MultMultiplier", "SCRITCHY_EGGTIMER_MULT_MULTIPLIER", 0x48, "float", 0.01, 100000),
        ("Fan", "BatteryCapacityMult", "SCRITCHY_FAN_BATTERY_CAPACITY_MULT", 0x68, "float", 0.01, 100000),
        ("Fan", "BatteryChargeMult", "SCRITCHY_FAN_BATTERY_CHARGE_MULT", 0x6C, "float", 0.01, 100000),
        ("Fan", "SpeedMult", "SCRITCHY_FAN_SPEED_MULT", 0x70, "float", 0.01, 100000),
        ("Mundo", "ClaimSpeedMult", "SCRITCHY_MUNDO_CLAIM_SPEED_MULT", 0xB8, "float", 0.01, 100000),
        ("ScratchBot", "speedMult", "SCRITCHY_SCRATCHBOT_SPEED_MULT", 0xCC, "float", 0.01, 100000),
        ("ScratchBot", "extraSpeed", "SCRITCHY_SCRATCHBOT_EXTRA_SPEED", 0xD0, "float", 0.0, 100000),
        ("ScratchBot", "extraCapacity", "SCRITCHY_SCRATCHBOT_EXTRA_CAPACITY", 0xD4, "float", 0.0, 100000),
        ("ScratchBot", "extraStrength", "SCRITCHY_SCRATCHBOT_EXTRA_STRENGTH", 0xD8, "int", 0, 100000),
        ("SpellBook", "RechargeSpeedMult", "SCRITCHY_SPELLBOOK_RECHARGE_SPEED_MULT", 0x28, "float", 0.01, 100000),
    ]
    fields_lua = "{" + ",".join(
        "{class=" + lua_quote(cls) + ",name=" + lua_quote(name) + ",global=" + lua_quote(global_name)
        + f",off={offset},kind={lua_quote(kind)},lo={lo},hi={hi}" + "}"
        for cls, name, global_name, offset, kind, lo, hi in fields
    ) + "}"
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function closeEnough(a,b) return a and b and math.abs(a-b) <= 0.0001 * math.max(1, math.abs(b)) end",
        "local function findInstance(className)",
        "  local cached = rawget(_G, 'SCRITCHY_CACHED_' .. className)",
        "  if cached and cached ~= 0 then",
        "    local ok = pcall(function() readQword(cached) end)",
        "    if ok then return cached, 'cache' end",
        "    rawset(_G, 'SCRITCHY_CACHED_' .. className, nil)",
        "  end",
        "  local cls = mono_findClass and mono_findClass('', className)",
        "  if not cls then return nil, 'class_not_found_' .. className end",
        "  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}",
        "  if list[1] and list[1] ~= 0 then rawset(_G, 'SCRITCHY_CACHED_' .. className, list[1]); return list[1], 'mono_instance' end",
        "  return nil, 'instance_not_found_' .. className",
        "end",
        f"local FIELDS={fields_lua}",
        "local instances, sources = {}, {}",
        "for _, f in ipairs(FIELDS) do",
        "  if instances[f.class] == nil then",
        "    local ptr, source = findInstance(f.class)",
        "    instances[f.class] = ptr or false",
        "    sources[f.class] = source",
        "  end",
        "end",
        "local active = {}",
        "for _, f in ipairs(FIELDS) do",
        "  local ptr = instances[f.class]",
        "  if ptr and ptr ~= 0 then",
        "    local addr = ptr + f.off",
        "    local before = f.kind == 'int' and readInteger(addr) or readFloat(addr)",
        "    if before == nil then return 'ERR: read failed ' .. f.class .. '.' .. f.name end",
        "    local test = before + 1",
        "    if test > f.hi then test = before - 1 end",
        "    if test < f.lo then test = f.lo end",
        "    if f.kind == 'int' then test = math.floor(test); if test == before then test = math.min(f.hi, before + 1) end end",
        "    active[#active+1] = {field=f, ptr=ptr, before=before, test=test}",
        "    _G[f.global] = test",
        "  end",
        "end",
        "if #active == 0 then return 'ERR: no gadget instances found' end",
        "SCRITCHY_SAFE_ACTION='gadget_runtime_apply'",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local changed = ok1",
        "local parts = {}",
        "for _, item in ipairs(active) do",
        "  local f = item.field",
        "  local value = f.kind == 'int' and readInteger(item.ptr + f.off) or readFloat(item.ptr + f.off)",
        "  item.changed = value",
        "  if f.kind == 'int' then",
        "    if value ~= item.test then changed = false end",
        "  elseif not closeEnough(value, item.test) then changed = false end",
        "  _G[f.global] = item.before",
        "end",
        "SCRITCHY_SAFE_ACTION='gadget_runtime_apply'",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local restored = ok2",
        "for _, item in ipairs(active) do",
        "  local f = item.field",
        "  local value = f.kind == 'int' and readInteger(item.ptr + f.off) or readFloat(item.ptr + f.off)",
        "  item.restored = value",
        "  if f.kind == 'int' then",
        "    if value ~= item.before then restored = false end",
        "  elseif not closeEnough(value, item.before) then restored = false end",
        "  parts[#parts+1] = string.format('%s.%s %s -> %s -> %s', f.class, f.name, tostring(item.before), tostring(item.changed), tostring(item.restored))",
        "  _G[f.global] = nil",
        "end",
        "return string.format('gadget runtime restore fields=%d %s changed=%s restored=%s\\nAPPLY %s\\nRESTORE %s', #active, table.concat(parts, ' | '), tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def experimental_runtime_dispatcher_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function closeEnough(a,b) return a and b and math.abs(a-b) <= 0.0001 * math.max(1, math.abs(b)) end",
        "local function findInstance(className)",
        "  local cached = rawget(_G, 'SCRITCHY_CACHED_' .. className)",
        "  if cached and cached ~= 0 then",
        "    local ok = pcall(function() readQword(cached) end)",
        "    if ok then return cached, 'cache' end",
        "    rawset(_G, 'SCRITCHY_CACHED_' .. className, nil)",
        "  end",
        "  local cls = mono_findClass and mono_findClass('', className)",
        "  if not cls then return nil, 'class_not_found_' .. className end",
        "  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}",
        "  if list[1] and list[1] ~= 0 then rawset(_G, 'SCRITCHY_CACHED_' .. className, list[1]); return list[1], 'mono_instance' end",
        "  return nil, 'instance_not_found_' .. className",
        "end",
        "local bot, botSource = findInstance('ScratchBot')",
        "local mundo, mundoSource = findInstance('Mundo')",
        "if not bot or bot == 0 then return 'ERR: ScratchBot nil source=' .. tostring(botSource) end",
        "if not mundo or mundo == 0 then return 'ERR: Mundo nil source=' .. tostring(mundoSource) end",
        "local duration0 = readFloat(bot + 0x48)",
        "local paused0 = readBytes(mundo + 0xBC, 1, false)",
        "if duration0 == nil or paused0 == nil then return 'ERR: read failed duration=' .. tostring(duration0) .. ' paused=' .. tostring(paused0) end",
        "local durationTest = duration0 + 0.25",
        "if durationTest > 3600 then durationTest = math.max(0.01, duration0 - 0.25) end",
        "if durationTest < 0.01 then durationTest = 0.01 end",
        "local pausedTest = paused0 == 1 and 0 or 1",
        "SCRITCHY_SAFE_ACTION='experimental_runtime_apply'",
        "SCRITCHY_SCRATCHBOT_PROCESSING_DURATION=durationTest",
        "SCRITCHY_MUNDO_PAUSED=pausedTest",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local duration1 = readFloat(bot + 0x48)",
        "local paused1 = readBytes(mundo + 0xBC, 1, false)",
        "SCRITCHY_SAFE_ACTION='experimental_runtime_apply'",
        "SCRITCHY_SCRATCHBOT_PROCESSING_DURATION=duration0",
        "SCRITCHY_MUNDO_PAUSED=paused0",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local duration2 = readFloat(bot + 0x48)",
        "local paused2 = readBytes(mundo + 0xBC, 1, false)",
        "local changed = ok1 and closeEnough(duration1, durationTest) and paused1 == pausedTest",
        "local restored = ok2 and closeEnough(duration2, duration0) and paused2 == paused0",
        "return string.format('experimental runtime restore botSource=%s mundoSource=%s duration %.6g -> %.6g -> %.6g paused %s -> %s -> %s changed=%s restored=%s\\nAPPLY %s\\nRESTORE %s', tostring(botSource), tostring(mundoSource), duration0, duration1, duration2, tostring(paused0), tostring(paused1), tostring(paused2), tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def ticket_progress_dispatcher_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function hx(v) return v and string.format('0x%X', v) or 'nil' end",
        "local function findSaveData()",
        "  local cached = rawget(_G, 'SCRITCHY_CACHED_SAVEDATA')",
        "  if cached and cached ~= 0 then",
        "    local layer = readQword(cached + 0x30)",
        "    if layer and layer ~= 0 then return cached, 'cache' end",
        "    rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', nil)",
        "  end",
        "  local cls = mono_findClass and mono_findClass('', 'SaveData')",
        "  if not cls then return nil, 'class_not_found' end",
        "  local saddr = mono_class_getStaticFieldAddress(0, cls)",
        "  if not saddr or saddr == 0 then return nil, 'static_not_found' end",
        "  for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do",
        "    if f.name == '_current' or f.name == 'current' then",
        "      local p = readQword(saddr + f.offset)",
        "      if p and p ~= 0 then rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', p); return p, 'mono_static' end",
        "    end",
        "  end",
        "  return nil, 'current_nil'",
        "end",
        "local function rstr(p) if not p or p == 0 then return nil end return readString(p + 0x14, 256, true) end",
        "local function findTicket(ticketId)",
        "  local saveData, source = findSaveData()",
        "  if not saveData or saveData == 0 then return nil, nil, 'SaveData nil source=' .. tostring(source) end",
        "  local layerOne = readQword(saveData + 0x30)",
        "  if not layerOne or layerOne == 0 then return nil, nil, 'layerOne nil saveData=' .. hx(saveData) end",
        "  local dict = readQword(layerOne + 0x20)",
        "  local entries = dict and readQword(dict + 0x18) or nil",
        "  if not entries or entries == 0 then return nil, nil, 'ticketProgressionDict entries nil dict=' .. hx(dict) end",
        "  local arrlen = readInteger(entries + 0x18, 4) or 0",
        "  for i=0,arrlen-1 do",
        "    local e = entries + 0x20 + i * 24",
        "    local hash = readInteger(e, 4)",
        "    local key = readQword(e + 8)",
        "    local val = readQword(e + 16)",
        "    if hash and hash >= 0 and val and val ~= 0 and rstr(key) == ticketId then return val, tostring(source), nil end",
        "  end",
        "  return nil, tostring(source), 'ticket_not_found'",
        "end",
        "local ticketId = 'Lucky Cat'",
        "local val, source, err = findTicket(ticketId)",
        "if not val or val == 0 then return 'ERR: ' .. tostring(err) .. ' ticket=' .. ticketId end",
        "local xp0 = readInteger(val + 0x18)",
        "local level0 = readInteger(val + 0x1C)",
        "if xp0 == nil or level0 == nil then return 'ERR: read failed xp=' .. tostring(xp0) .. ' level=' .. tostring(level0) end",
        "local xpTest = xp0 + 1",
        "if xpTest > 2147483640 then xpTest = xp0 - 1 end",
        "if xpTest < 0 then xpTest = 1 end",
        "local levelTest = level0 + 1",
        "if levelTest > 100000 then levelTest = level0 - 1 end",
        "if levelTest < 0 then levelTest = 1 end",
        "SCRITCHY_SAFE_ACTION='ticket_progress_apply'",
        "SCRITCHY_TICKET_ID=ticketId",
        "SCRITCHY_TICKET_LEVEL=levelTest",
        "SCRITCHY_TICKET_XP=xpTest",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local xp1 = readInteger(val + 0x18)",
        "local level1 = readInteger(val + 0x1C)",
        "SCRITCHY_SAFE_ACTION='ticket_progress_apply'",
        "SCRITCHY_TICKET_ID=ticketId",
        "SCRITCHY_TICKET_LEVEL=level0",
        "SCRITCHY_TICKET_XP=xp0",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local xp2 = readInteger(val + 0x18)",
        "local level2 = readInteger(val + 0x1C)",
        "local changed = ok1 and xp1 == xpTest and level1 == levelTest",
        "local restored = ok2 and xp2 == xp0 and level2 == level0",
        "return string.format('ticket progress restore ok1=%s ok2=%s source=%s ticket=%s level %s -> %s -> %s xp %s -> %s -> %s changed=%s restored=%s\\nAPPLY %s\\nRESTORE %s', tostring(ok1), tostring(ok2), tostring(source), ticketId, tostring(level0), tostring(level1), tostring(level2), tostring(xp0), tostring(xp1), tostring(xp2), tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def helper_state_dispatcher_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function hx(v) return v and string.format('0x%X', v) or 'nil' end",
        "local function closeEnough(a,b) return a and b and math.abs(a-b) <= 0.0001 * math.max(1, math.abs(b)) end",
        "local function looseEnough(a,b) return a and b and math.abs(a-b) <= 0.05 * math.max(1, math.abs(b)) end",
        "local function resultHasFloat(text,label,target)",
        "  local pattern = label .. '=[^\\n]*%-> ([^\\n]+)'",
        "  local raw = tostring(text):match(pattern)",
        "  local value = tonumber(raw)",
        "  return value ~= nil and looseEnough(value, target), value",
        "end",
        "local function resultHasBool(text,label,target)",
        "  local pattern = label .. '=[^\\n]*%-> ([^\\n]+)'",
        "  local raw = tostring(text):match(pattern)",
        "  local value = tostring(raw):lower()",
        "  local want = (target == 1) and 'true' or 'false'",
        "  return value == want, value",
        "end",
        "local function getSaveData()",
        "  local cached = rawget(_G, 'SCRITCHY_CACHED_SAVEDATA')",
        "  if cached and cached ~= 0 then",
        "    local layer = readQword(cached + 0x30)",
        "    if layer and layer ~= 0 then return cached, 'cache' end",
        "    rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', nil)",
        "  end",
        "  local cls = mono_findClass and mono_findClass('', 'SaveData')",
        "  if not cls then return nil, 'class_not_found' end",
        "  local saddr = mono_class_getStaticFieldAddress(0, cls)",
        "  if not saddr or saddr == 0 then return nil, 'static_not_found' end",
        "  for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do",
        "    if f.name == '_current' or f.name == 'current' then",
        "      local p = readQword(saddr + f.offset)",
        "      if p and p ~= 0 then rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', p); return p, 'mono_static' end",
        "    end",
        "  end",
        "  return nil, 'current_nil'",
        "end",
        "local saveData, source = getSaveData()",
        "if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end",
        "local layerOne = readQword(saveData + 0x30)",
        "if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData=' .. hx(saveData) end",
        "local fan0 = readFloat(layerOne + 0x98)",
        "local paused0 = readBytes(layerOne + 0x9C, 1, false)",
        "local egg0 = readFloat(layerOne + 0xA0)",
        "local mundo0 = readBytes(layerOne + 0xA4, 1, false)",
        "local trash0 = readBytes(layerOne + 0xA5, 1, false)",
        "if fan0 == nil or paused0 == nil or egg0 == nil or mundo0 == nil or trash0 == nil then return 'ERR: read helper state failed' end",
        "local fanTest = fan0 + 1",
        "if fanTest > 100000 then fanTest = math.max(0, fan0 - 1) end",
        "local eggTest = egg0 + 1",
        "if eggTest > 100000 then eggTest = math.max(0, egg0 - 1) end",
        "local pausedTest = paused0 == 1 and 0 or 1",
        "local mundoTest = mundo0 == 1 and 0 or 1",
        "local trashTest = trash0 == 1 and 0 or 1",
        "SCRITCHY_SAFE_ACTION='helper_state_apply'",
        "SCRITCHY_ELECTRIC_FAN_CHARGE_LEFT=fanTest",
        "SCRITCHY_FAN_PAUSED=pausedTest",
        "SCRITCHY_EGG_TIMER_CHARGE_LEFT=eggTest",
        "SCRITCHY_MUNDO_DEAD=mundoTest",
        "SCRITCHY_TRASH_CAN_DEAD=trashTest",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local fan1 = readFloat(layerOne + 0x98)",
        "local paused1 = readBytes(layerOne + 0x9C, 1, false)",
        "local egg1 = readFloat(layerOne + 0xA0)",
        "local mundo1 = readBytes(layerOne + 0xA4, 1, false)",
        "local trash1 = readBytes(layerOne + 0xA5, 1, false)",
        "local fanApplied, fanEcho = resultHasFloat(res1, 'electricFanChargeLeft', fanTest)",
        "local pausedApplied, pausedEcho = resultHasBool(res1, 'fanPaused', pausedTest)",
        "local eggApplied, eggEcho = resultHasFloat(res1, 'eggTimerChargeLeft', eggTest)",
        "local mundoApplied, mundoEcho = resultHasBool(res1, 'mundoDead', mundoTest)",
        "local trashApplied, trashEcho = resultHasBool(res1, 'trashCanDead', trashTest)",
        "SCRITCHY_SAFE_ACTION='helper_state_apply'",
        "SCRITCHY_ELECTRIC_FAN_CHARGE_LEFT=fan0",
        "SCRITCHY_FAN_PAUSED=paused0",
        "SCRITCHY_EGG_TIMER_CHARGE_LEFT=egg0",
        "SCRITCHY_MUNDO_DEAD=mundo0",
        "SCRITCHY_TRASH_CAN_DEAD=trash0",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local fan2 = readFloat(layerOne + 0x98)",
        "local paused2 = readBytes(layerOne + 0x9C, 1, false)",
        "local egg2 = readFloat(layerOne + 0xA0)",
        "local mundo2 = readBytes(layerOne + 0xA4, 1, false)",
        "local trash2 = readBytes(layerOne + 0xA5, 1, false)",
        "local changed = ok1 and fanApplied and pausedApplied and eggApplied and mundoApplied and trashApplied",
        "local restored = ok2 and closeEnough(fan2, fan0) and paused2 == paused0 and closeEnough(egg2, egg0) and mundo2 == mundo0 and trash2 == trash0",
        "return string.format('helper state restore source=%s fan %.6g -> %.6g -> %.6g echo=%s paused %s -> %s -> %s echo=%s egg %.6g -> %.6g -> %.6g echo=%s mundo %s -> %s -> %s echo=%s trash %s -> %s -> %s echo=%s changed=%s restored=%s\\nAPPLY %s\\nRESTORE %s', tostring(source), fan0, fan1, fan2, tostring(fanEcho), tostring(paused0), tostring(paused1), tostring(paused2), tostring(pausedEcho), egg0, egg1, egg2, tostring(eggEcho), tostring(mundo0), tostring(mundo1), tostring(mundo2), tostring(mundoEcho), tostring(trash0), tostring(trash1), tostring(trash2), tostring(trashEcho), tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def loan_state_dispatcher_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function hx(v) return v and string.format('0x%X', v) or 'nil' end",
        "local function closeEnough(a,b) return a and b and math.abs(a-b) <= 0.0001 * math.max(1, math.abs(b)) end",
        "local function getSaveData()",
        "  local cached = rawget(_G, 'SCRITCHY_CACHED_SAVEDATA')",
        "  if cached and cached ~= 0 then",
        "    local layer = readQword(cached + 0x30)",
        "    if layer and layer ~= 0 then return cached, 'cache' end",
        "    rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', nil)",
        "  end",
        "  local cls = mono_findClass and mono_findClass('', 'SaveData')",
        "  if not cls then return nil, 'class_not_found' end",
        "  local saddr = mono_class_getStaticFieldAddress(0, cls)",
        "  if not saddr or saddr == 0 then return nil, 'static_not_found' end",
        "  for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do",
        "    if f.name == '_current' or f.name == 'current' then",
        "      local p = readQword(saddr + f.offset)",
        "      if p and p ~= 0 then rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', p); return p, 'mono_static' end",
        "    end",
        "  end",
        "  return nil, 'current_nil'",
        "end",
        "local function listInfo(list)",
        "  if not list or list == 0 then return {list=list or 0, items=0, size=0, capacity=0} end",
        "  local items = readQword(list + 0x10) or 0",
        "  local size = readInteger(list + 0x18) or 0",
        "  local capacity = items ~= 0 and (readInteger(items + 0x18) or 0) or 0",
        "  return {list=list, items=items, size=size, capacity=capacity}",
        "end",
        "local function firstLoan(info)",
        "  if not info or info.items == 0 or info.capacity <= 0 then return 0 end",
        "  return readQword(info.items + 0x20) or 0",
        "end",
        "local saveData, source = getSaveData()",
        "if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end",
        "local layerOne = readQword(saveData + 0x30)",
        "if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData=' .. hx(saveData) end",
        "local loans = readQword(layerOne + 0x70)",
        "local info = listInfo(loans)",
        "local count0 = readInteger(saveData + 0xC0)",
        "local size0 = info.size",
        "if count0 == nil or size0 == nil then return 'ERR: loan count/list read failed count=' .. tostring(count0) .. ' size=' .. tostring(size0) end",
        "local loan0 = firstLoan(info)",
        "local hasLoan = loan0 and loan0 ~= 0",
        "local idx0, num0, sev0, amount0 = nil, nil, nil, nil",
        "if hasLoan then idx0=readInteger(loan0+0x18); num0=readInteger(loan0+0x1C); sev0=readInteger(loan0+0x20); amount0=readDouble(loan0+0x28) end",
        "local countTest = count0 + 1",
        "if countTest > 100000 then countTest = math.max(0, count0 - 1) end",
        "local sizeTest = size0",
        "if info.capacity > 0 then sizeTest = math.min(info.capacity, size0 + 1); if sizeTest == size0 and size0 > 0 then sizeTest = size0 - 1 end end",
        "local idxTest, numTest, sevTest, amountTest = idx0, num0, sev0, amount0",
        "if hasLoan then",
        "  idxTest = (idx0 or 0) + 1",
        "  numTest = (num0 or 0) + 1",
        "  sevTest = (sev0 or 0) + 1",
        "  amountTest = (amount0 or 0) + 1.25",
        "end",
        "SCRITCHY_SAFE_ACTION='loan_apply'",
        "SCRITCHY_LOAN_COUNT=countTest",
        "SCRITCHY_LOAN_LIST_SIZE=sizeTest",
        "if hasLoan then SCRITCHY_LOAN_INDEX=idxTest; SCRITCHY_LOAN_NUM=numTest; SCRITCHY_LOAN_SEVERITY=sevTest; SCRITCHY_LOAN_AMOUNT=amountTest end",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local info1 = listInfo(readQword(layerOne + 0x70))",
        "local count1 = readInteger(saveData + 0xC0)",
        "local size1 = info1.size",
        "local loan1 = firstLoan(info1)",
        "local idx1, num1, sev1, amount1 = nil, nil, nil, nil",
        "if hasLoan and loan1 ~= 0 then idx1=readInteger(loan1+0x18); num1=readInteger(loan1+0x1C); sev1=readInteger(loan1+0x20); amount1=readDouble(loan1+0x28) end",
        "SCRITCHY_SAFE_ACTION='loan_apply'",
        "SCRITCHY_LOAN_COUNT=count0",
        "SCRITCHY_LOAN_LIST_SIZE=size0",
        "if hasLoan then SCRITCHY_LOAN_INDEX=idx0; SCRITCHY_LOAN_NUM=num0; SCRITCHY_LOAN_SEVERITY=sev0; SCRITCHY_LOAN_AMOUNT=amount0 end",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local info2 = listInfo(readQword(layerOne + 0x70))",
        "local count2 = readInteger(saveData + 0xC0)",
        "local size2 = info2.size",
        "local loan2 = firstLoan(info2)",
        "local idx2, num2, sev2, amount2 = nil, nil, nil, nil",
        "if hasLoan and loan2 ~= 0 then idx2=readInteger(loan2+0x18); num2=readInteger(loan2+0x1C); sev2=readInteger(loan2+0x20); amount2=readDouble(loan2+0x28) end",
        "local changed = ok1 and count1 == countTest and size1 == sizeTest",
        "local restored = ok2 and count2 == count0 and size2 == size0",
        "if hasLoan then changed = changed and idx1 == idxTest and num1 == numTest and sev1 == sevTest and closeEnough(amount1, amountTest); restored = restored and idx2 == idx0 and num2 == num0 and sev2 == sev0 and closeEnough(amount2, amount0) end",
        "return string.format('loan state restore source=%s hasLoan=%s count %s -> %s -> %s size %s -> %s -> %s changed=%s restored=%s\\nfirstLoan index %s -> %s -> %s loanNum %s -> %s -> %s severity %s -> %s -> %s amount %s -> %s -> %s\\nAPPLY %s\\nRESTORE %s', tostring(source), tostring(hasLoan), tostring(count0), tostring(count1), tostring(count2), tostring(size0), tostring(size1), tostring(size2), tostring(changed), tostring(restored), tostring(idx0), tostring(idx1), tostring(idx2), tostring(num0), tostring(num1), tostring(num2), tostring(sev0), tostring(sev1), tostring(sev2), tostring(amount0), tostring(amount1), tostring(amount2), tostring(res1), tostring(res2))",
    ])


def loan_clear_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local function getSaveData()",
        "  local cached = rawget(_G, 'SCRITCHY_CACHED_SAVEDATA')",
        "  if cached and cached ~= 0 then",
        "    local layer = readQword(cached + 0x30)",
        "    if layer and layer ~= 0 then return cached, 'cache' end",
        "    rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', nil)",
        "  end",
        "  local cls = mono_findClass and mono_findClass('', 'SaveData')",
        "  if not cls then return nil, 'class_not_found' end",
        "  local saddr = mono_class_getStaticFieldAddress(0, cls)",
        "  if not saddr or saddr == 0 then return nil, 'static_not_found' end",
        "  for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do",
        "    if f.name == '_current' or f.name == 'current' then",
        "      local p = readQword(saddr + f.offset)",
        "      if p and p ~= 0 then rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', p); return p, 'mono_static' end",
        "    end",
        "  end",
        "  return nil, 'current_nil'",
        "end",
        "local function listInfo(list)",
        "  if not list or list == 0 then return {list=list or 0, items=0, size=0, capacity=0} end",
        "  local items = readQword(list + 0x10) or 0",
        "  local size = readInteger(list + 0x18) or 0",
        "  local capacity = items ~= 0 and (readInteger(items + 0x18) or 0) or 0",
        "  return {list=list, items=items, size=size, capacity=capacity}",
        "end",
        "local saveData, source = getSaveData()",
        "if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end",
        "local layerOne = readQword(saveData + 0x30)",
        "if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData' end",
        "local info0 = listInfo(readQword(layerOne + 0x70))",
        "local count0 = readInteger(saveData + 0xC0)",
        "local size0 = info0.size",
        "SCRITCHY_SAFE_ACTION='loan_clear'",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local info1 = listInfo(readQword(layerOne + 0x70))",
        "local count1 = readInteger(saveData + 0xC0)",
        "local size1 = info1.size",
        "SCRITCHY_SAFE_ACTION='loan_apply'",
        "SCRITCHY_LOAN_COUNT=count0",
        "SCRITCHY_LOAN_LIST_SIZE=size0",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local info2 = listInfo(readQword(layerOne + 0x70))",
        "local count2 = readInteger(saveData + 0xC0)",
        "local size2 = info2.size",
        "local changed = ok1 and count1 == 0 and size1 == 0",
        "local restored = ok2 and count2 == count0 and size2 == size0",
        "return string.format('loan clear restore source=%s count %s -> %s -> %s size %s -> %s -> %s changed=%s restored=%s\\nCLEAR %s\\nRESTORE %s', tostring(source), tostring(count0), tostring(count1), tostring(count2), tostring(size0), tostring(size1), tostring(size2), tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def single_perk_restore_lua() -> str:
    path = str(SAFE_SUITE).replace("\\", "\\\\")
    return "\n".join([
        f"openProcess('{GAME_EXE}')",
        "pcall(LaunchMonoDataCollector)",
        "local target = 'Muscle Memory'",
        "local function safeString(sp) if sp and sp ~= 0 and sp < 0x0000800000000000 then return readString(sp + 0x14, 128, true) end return nil end",
        "local function findActive(id)",
        "  local cls = mono_findClass and mono_findClass('', 'PerkManager')",
        "  if not cls then return nil, 'class_not_found' end",
        "  local manager = (mono_class_findInstancesOfClassListOnly(nil, cls) or {})[1]",
        "  if not manager or manager == 0 then return nil, 'manager_nil' end",
        "  local dict = readQword(manager + 0x28)",
        "  local entries = dict and readQword(dict + 0x18) or nil",
        "  if not entries or entries == 0 then return nil, 'entries_nil' end",
        "  local arrlen = readInteger(entries + 0x18, 4) or 0",
        "  for i=0,arrlen-1 do",
        "    local entry = entries + 0x20 + i * 0x18",
        "    local hash = readInteger(entry, 4)",
        "    local key = readInteger(entry + 0x08, 4)",
        "    local tuple = readQword(entry + 0x10)",
        "    if hash and hash >= 0 and tuple and tuple ~= 0 and tuple < 0x0000800000000000 then",
        "      local perkData = readQword(tuple + 0x10)",
        "      local name = perkData and safeString(readQword(perkData + 0x10)) or nil",
        "      if name == id then return {manager=manager, tuple=tuple, perkData=perkData, key=key, entry=i}, nil end",
        "    end",
        "  end",
        "  return nil, 'not_found'",
        "end",
        "local item, err = findActive(target)",
        "if not item then return 'ERR: ' .. tostring(err) .. ' target=' .. target end",
        "local item0 = readInteger(item.tuple + 0x18, 4)",
        "local perk0 = readInteger(item.perkData + 0x30, 4)",
        "if item0 == nil or perk0 == nil then return 'ERR: read active failed' end",
        "local test = item0 + 1",
        "if test > 100000 then test = math.max(0, item0 - 1) end",
        "SCRITCHY_SAFE_ACTION='single_perk_apply'",
        "SCRITCHY_SINGLE_PERK_TARGET=target",
        "SCRITCHY_SINGLE_PERK_COUNT=test",
        f"local ok1,res1=pcall(dofile,{lua_quote(path)})",
        "local item1 = readInteger(item.tuple + 0x18, 4)",
        "local perk1 = readInteger(item.perkData + 0x30, 4)",
        "SCRITCHY_SAFE_ACTION='single_perk_apply'",
        "SCRITCHY_SINGLE_PERK_TARGET=target",
        "SCRITCHY_SINGLE_PERK_TUPLE_COUNT=item0",
        "SCRITCHY_SINGLE_PERK_PERKDATA_COUNT=perk0",
        "SCRITCHY_SINGLE_PERK_SAVE_COUNT=item0",
        f"local ok2,res2=pcall(dofile,{lua_quote(path)})",
        "local item2 = readInteger(item.tuple + 0x18, 4)",
        "local perk2 = readInteger(item.perkData + 0x30, 4)",
        "local changed = ok1 and item1 == test and perk1 == test and tostring(res1):find('changed=true') ~= nil",
        "local restored = ok2 and item2 == item0 and perk2 == perk0 and tostring(res2):find('changed=true') ~= nil",
        "return string.format('single perk restore target=%s type=%s tupleItem2 %s -> %s -> %s perkCount %s -> %s -> %s changed=%s restored=%s\\nAPPLY %s\\nRESTORE %s', target, tostring(item.key), tostring(item0), tostring(item1), tostring(item2), tostring(perk0), tostring(perk1), tostring(perk2), tostring(changed), tostring(restored), tostring(res1), tostring(res2))",
    ])


def run_lua(code: str) -> str:
    client = CEClient()
    try:
        client.connect()
        res = client.lua(code)
        if not res.get("success", False):
            raise RuntimeError(str(res))
        return str(res.get("result", ""))
    finally:
        client.close()


def run_case_with_client(client: CEClient, name: str, code: str, timeout_sec: int) -> VerifyResult:
    started = time.time()
    try:
        res = client.lua(code)
        if not res.get("success", False):
            raise RuntimeError(str(res))
        raw = str(res.get("result", ""))
        ok = classify_ok(name, raw)
        return VerifyResult(name, ok, round(time.time() - started, 3), summarize(name, raw), raw, "" if ok else "classification failed")
    except Exception as exc:
        return VerifyResult(name, False, round(time.time() - started, 3), repr(exc), error=repr(exc))


def run_case(name: str, code: str, timeout_sec: int) -> VerifyResult:
    client = CEClient()
    try:
        client.connect(min(30000, max(8000, timeout_sec * 1000)))
        return run_case_with_client(client, name, code, timeout_sec)
    finally:
        client.close()


def _case_worker(out: mp.Queue, name: str, code: str, timeout_sec: int) -> None:
    try:
        out.put(run_case(name, code, timeout_sec))
    except Exception as exc:
        out.put(VerifyResult(name, False, 0, repr(exc), error=repr(exc)))


def run_case_isolated(name: str, code: str, timeout_sec: int) -> VerifyResult:
    out: mp.Queue = mp.Queue()
    proc = mp.Process(target=_case_worker, args=(out, name, code, timeout_sec), daemon=True)
    started = time.time()
    proc.start()
    proc.join(timeout_sec + 5)
    if proc.is_alive():
        proc.terminate()
        proc.join(2)
        return VerifyResult(name, False, round(time.time() - started, 3), f"timeout after {timeout_sec}s", error="timeout")
    try:
        item = out.get_nowait()
    except queue.Empty:
        return VerifyResult(name, False, round(time.time() - started, 3), "worker exited without result", error="no result")
    item.duration_sec = round(time.time() - started, 3)
    return item


def strip(raw: str) -> str:
    for prefix in ("true :: true :: ", "true :: "):
        if raw.startswith(prefix):
            return raw[len(prefix):]
    return raw


def classify_ok(name: str, raw: str) -> bool:
    text = strip(raw)
    if name in {
        "custom_save_fields_restore",
        "scratch_runtime_dispatcher_restore",
        "bot_upgrade_dispatcher_restore",
        "subscription_bot_dispatcher_restore",
        "subscription_runtime_write_restore",
        "subscription_runtime_dispatcher_restore",
        "gadget_runtime_dispatcher_restore",
        "experimental_runtime_dispatcher_restore",
        "helper_upgrade_dispatcher_restore",
        "ticket_progress_dispatcher_restore",
        "helper_state_dispatcher_restore",
        "loan_state_dispatcher_restore",
        "loan_clear_restore",
        "single_perk_restore",
        "rng_patch_restore",
        "free_patch_restore",
    }:
        return "ERR" not in text and "error" not in text.lower() and "changed=true" in text and "restored=true" in text
    if not raw.startswith("true ::"):
        return False
    if "ERR" in text or "error" in text.lower():
        return False
    patterns = {
        "runtime_status": "存档:",
        "dump": "SaveData=",
        "dump_perks": "valid=",
        "scratch_status": "scratchChecksPerSecond",
        "bot_upgrade_status": "Scratch Bot Speed",
        "subscription_bot_status": ["mode=status", "Subscription Bot", "Buying Speed", "max="],
        "subscription_runtime_status": ["processingDuration", "maxTicketCount", "paused=", "currentTicket", "ProcessingSpeedMult"],
        "gadget_runtime_status": ["gadget runtime mode=status", "OK touchedFields=0"],
        "experimental_runtime_status": ["experimental runtime mode=status", "ScratchBot.processingDuration", "Mundo.paused"],
        "helper_upgrade_status": ["helper upgrades", "mode=status", "Fan Speed", "Warp Speed"],
        "ticket_progress_status": ["ticket progression", "mode=status", "ticket=Lucky Cat", "level "],
        "helper_state_status": ["helper state", "mode=status", "electricFanChargeLeft", "trashCanDead"],
        "loan_status": ["loan state", "mode=status", "loanCount"],
        "automation_perks_status": ["mode=status", "dryrun=true", "HandsOff", "Fully", "OK changed="],
        "single_perk_status": ["single perk", "mode=status", "Muscle Memory"],
        "automation_perks_apply": ["mode=apply", "dryrun=false", "OK changed=", "saveChanged="],
        "free_dryrun": "mode=DRYRUN",
        "symbol_dump": ["ticket\tsymbolId", "Lucky Cat", "Gold Coin"],
        "sjp_max": "directOk=true",
        "symbol_dryrun": "dryrun=true",
        "symbol_type_dryrun": ["type=1", "dryrun=true", "OK touchedSymbols="],
        "symbol_write_restore": ["changed=true", "restored=true"],
        "custom_tokens": "tokens ",
        "custom_money_1": "money ",
        "custom_money_2": "money ",
        "scratch_apply_same": "scratchChecksPerSecond",
        "bot_upgrade_apply_same": "Scratch Bot Speed",
        "subscription_bot_apply_same": ["mode=apply", "Subscription Bot", "Buying Speed", "max="],
        "online_unlock_same": "progressTouched=43",
        "rng_enable": "OK patched",
        "rng_disable": "UNINSTALL OK",
    }
    expected = patterns.get(name)
    if expected is None:
        return False
    if isinstance(expected, list):
        return all(item in text for item in expected)
    return expected in text


def summarize(name: str, raw: str, error: str = "") -> str:
    if error:
        return error
    text = strip(raw)
    lines = [line for line in text.splitlines() if line.strip()]
    if name == "runtime_status":
        return " | ".join(lines[:3])
    if name == "sjp_max":
        target = re.search(r"targetValue=([^\s]+)", text)
        boosted = re.search(r"boosted=(\d+)", text)
        return f"target={target.group(1) if target else '?'} boosted={boosted.group(1) if boosted else '?'}"
    useful = [line for line in lines if " -> " in line or line.startswith("OK") or "mode=DRYRUN" in line]
    return " | ".join((useful or lines)[:4])


def build_cases(include_destructive: bool = False) -> list[tuple[str, str, int]]:
    safe_cases = [
        ("runtime_status", suite_lua("runtime_status"), 20),
        ("dump", suite_lua("dump"), 25),
        ("dump_perks", suite_lua("dump_perks"), 20),
        ("custom_save_fields_restore", custom_save_fields_restore_lua(), 70),
        ("scratch_status", suite_lua("scratch_status"), 20),
        ("scratch_runtime_dispatcher_restore", scratch_runtime_dispatcher_restore_lua(), 70),
        ("bot_upgrade_status", suite_lua("bot_upgrade_status"), 20),
        ("bot_upgrade_dispatcher_restore", upgrade_dispatcher_restore_lua("bot_upgrade_apply", ["Scratch Bot", "Scratch Bot Speed", "Scratch Bot Capacity", "Scratch Bot Strength"], {
            "Scratch Bot": "SCRITCHY_BOT_UNLOCK",
            "Scratch Bot Speed": "SCRITCHY_BOT_SPEED",
            "Scratch Bot Capacity": "SCRITCHY_BOT_CAPACITY",
            "Scratch Bot Strength": "SCRITCHY_BOT_STRENGTH",
        }), 90),
        ("subscription_bot_status", suite_lua("subscription_bot_status"), 45),
        ("subscription_bot_dispatcher_restore", upgrade_dispatcher_restore_lua("subscription_bot_apply", ["Subscription Bot", "Buying Speed"], {
            "Subscription Bot": "SCRITCHY_SUB_BOT_UNLOCK",
            "Buying Speed": "SCRITCHY_BUYING_SPEED",
        }), 90),
        ("subscription_runtime_status", suite_lua("subscription_runtime_status"), 30),
        ("subscription_runtime_write_restore", subscription_runtime_write_restore_lua(), 45),
        ("subscription_runtime_dispatcher_restore", subscription_runtime_dispatcher_restore_lua(), 90),
        ("gadget_runtime_status", suite_lua("gadget_runtime_status"), 35),
        ("gadget_runtime_dispatcher_restore", gadget_runtime_dispatcher_restore_lua(), 120),
        ("experimental_runtime_status", suite_lua("experimental_runtime_status"), 35),
        ("experimental_runtime_dispatcher_restore", experimental_runtime_dispatcher_restore_lua(), 90),
        ("helper_upgrade_status", suite_lua("helper_upgrade_status"), 30),
        ("helper_upgrade_dispatcher_restore", upgrade_dispatcher_restore_lua("helper_upgrade_apply", ["Fan", "Fan Speed", "Fan Battery", "Mundo", "Mundo Speed", "Spell Book", "Spell Charge Speed", "Egg Timer", "Timer Capacity", "Timer Charge", "Warp Speed"], {
            "Fan": "SCRITCHY_UPGRADE_FAN",
            "Fan Speed": "SCRITCHY_UPGRADE_FAN_SPEED",
            "Fan Battery": "SCRITCHY_UPGRADE_FAN_BATTERY",
            "Mundo": "SCRITCHY_UPGRADE_MUNDO",
            "Mundo Speed": "SCRITCHY_UPGRADE_MUNDO_SPEED",
            "Spell Book": "SCRITCHY_UPGRADE_SPELL_BOOK",
            "Spell Charge Speed": "SCRITCHY_UPGRADE_SPELL_CHARGE_SPEED",
            "Egg Timer": "SCRITCHY_UPGRADE_EGG_TIMER",
            "Timer Capacity": "SCRITCHY_UPGRADE_TIMER_CAPACITY",
            "Timer Charge": "SCRITCHY_UPGRADE_TIMER_CHARGE",
            "Warp Speed": "SCRITCHY_UPGRADE_WARP_SPEED",
        }, {
            "Fan": 1,
            "Fan Speed": 5,
            "Fan Battery": 5,
            "Mundo": 1,
            "Mundo Speed": 10,
            "Spell Book": 1,
            "Spell Charge Speed": 10,
            "Egg Timer": 1,
            "Timer Capacity": 10,
            "Timer Charge": 10,
            "Warp Speed": 3,
        }), 120),
        ("ticket_progress_status", suite_lua("ticket_progress_status", "SCRITCHY_TICKET_ID='Lucky Cat'"), 30),
        ("ticket_progress_dispatcher_restore", ticket_progress_dispatcher_restore_lua(), 90),
        ("helper_state_status", suite_lua("helper_state_status"), 20),
        ("helper_state_dispatcher_restore", helper_state_dispatcher_restore_lua(), 90),
        ("loan_status", suite_lua("loan_status"), 20),
        ("loan_state_dispatcher_restore", loan_state_dispatcher_restore_lua(), 90),
        ("loan_clear_restore", loan_clear_restore_lua(), 90),
        ("automation_perks_status", suite_lua("automation_perks_status"), 30),
        ("single_perk_status", suite_lua("single_perk_status", "SCRITCHY_SINGLE_PERK_TARGET='Muscle Memory'"), 30),
        ("single_perk_restore", single_perk_restore_lua(), 90),
        ("free_dryrun", suite_lua("free_dryrun"), 20),
        ("free_patch_restore", free_patch_restore_lua(), 70),
        ("symbol_dump", suite_lua("symbol_dump", "SCRITCHY_SYMBOL_TICKET='Lucky Cat'"), 30),
        ("symbol_dryrun", suite_lua("symbol_apply", "SCRITCHY_SYMBOL_TICKET='Lucky Cat'\nSCRITCHY_SYMBOL_ID='Gold Coin'\nSCRITCHY_SYMBOL_VALUE=99999\nSCRITCHY_SYMBOL_LUCK_INDEX=-1\nSCRITCHY_SYMBOL_DRYRUN=true"), 25),
        ("symbol_type_dryrun", symbol_type_dryrun_lua(), 25),
        ("symbol_write_restore", symbol_write_restore_lua(), 45),
        ("rng_patch_restore", rng_patch_restore_lua(), 70),
    ]
    if not include_destructive:
        return safe_cases
    return safe_cases + [
        ("custom_tokens", suite_lua("custom_save_fields", "SCRITCHY_CUSTOM_TOKENS=999999999"), 35),
        ("custom_money_1", suite_lua("custom_save_fields", "SCRITCHY_CUSTOM_MONEY=5e35"), 35),
        ("custom_money_2", suite_lua("custom_save_fields", "SCRITCHY_CUSTOM_MONEY=6e35"), 35),
        ("scratch_apply_same", suite_lua("scratch_apply", "SCRITCHY_SCRATCH_CHECKS_PER_SECOND=10"), 20),
        ("bot_upgrade_apply_same", suite_lua("bot_upgrade_apply", "SCRITCHY_BOT_UNLOCK=1\nSCRITCHY_BOT_SPEED=30\nSCRITCHY_BOT_CAPACITY=10\nSCRITCHY_BOT_STRENGTH=20"), 20),
        ("subscription_bot_apply_same", suite_lua("subscription_bot_apply", "SCRITCHY_SUB_BOT_UNLOCK=1\nSCRITCHY_BUYING_SPEED=10"), 45),
        ("automation_perks_apply", suite_lua("automation_perks_apply", "SCRITCHY_AUTOMATION_PERK_COUNT=1"), 30),
        ("sjp_max", suite_lua("sjp_max", "SJP_CHANCE_VALUE=99999"), 25),
        ("online_unlock_same", suite_lua("online_unlock", "SCRITCHY_UNLOCK_LEVEL=30\nSCRITCHY_UNLOCK_XP=9999"), 25),
        ("rng_enable", suite_lua("rng_enable"), 35),
        ("rng_disable", suite_lua("rng_disable"), 35),
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description="Scritchy Scratchy GUI function verification API")
    parser.add_argument("--case", action="append", dest="cases", help="Run only selected case name. Can be repeated.")
    parser.add_argument("--json", action="store_true", help="Print JSON only.")
    parser.add_argument("--report", type=Path, default=REPORT_PATH)
    parser.add_argument("--shared-client", action="store_true", help="Use one CE pipe connection for all cases. Faster but less robust.")
    parser.add_argument("--destructive", action="store_true", help="Also run legacy write-only persistence cases that do not restore live values.")
    parser.add_argument("--wait-ready", type=int, default=0, metavar="SEC", help="Wait until Scritchy Scratchy SaveData and LayerOne are initialized before running cases.")
    args = parser.parse_args()

    selected = set(args.cases or [])
    all_cases = build_cases(args.destructive)
    destructive_names = {case[0] for case in build_cases(True)} - {case[0] for case in build_cases(False)}
    available_names = {case[0] for case in all_cases}
    unknown = sorted(selected - available_names)
    if unknown:
        destructive_selected = [name for name in unknown if name in destructive_names]
        truly_unknown = [name for name in unknown if name not in destructive_names]
        payload = {
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            "ok": False,
            "passed": 0,
            "failed": len(unknown),
            "pipe_available_at_start": False,
            "pipe_state_at_start": "not_checked",
            "ready_state": "",
            "destructive_cases_included": args.destructive,
            "results": (
                [asdict(VerifyResult(name, False, 0, f"case requires --destructive: {name}", error="requires --destructive")) for name in destructive_selected]
                + [asdict(VerifyResult(name, False, 0, f"unknown case: {name}", error="unknown case")) for name in truly_unknown]
            ),
        }
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print(f"verify ok=False passed=0 failed={len(unknown)} report={args.report}")
            for name in destructive_selected:
                print(f"[FAIL] {name}: requires --destructive")
            for name in truly_unknown:
                print(f"[FAIL] {name}: unknown case")
        return 1
    cases = [case for case in all_cases if not selected or case[0] in selected]
    results = []
    pipe_ok, pipe_reason = pipe_probe(500)
    ready_state = ""
    if args.shared_client:
        client = CEClient()
        try:
            client.connect(30000)
            if args.wait_ready > 0:
                ready_state = wait_game_ready(client, args.wait_ready, args.json)
            for name, code, timeout in cases:
                results.append(run_case_with_client(client, name, code, timeout))
                time.sleep(0.4)
        except Exception as exc:
            if not results:
                results.append(VerifyResult("connect", False, 0, repr(exc), error=repr(exc)))
            else:
                results.append(VerifyResult("verify_loop", False, 0, repr(exc), error=repr(exc)))
        finally:
            client.close()
    else:
        if args.wait_ready > 0:
            client = CEClient()
            try:
                client.connect(30000)
                ready_state = wait_game_ready(client, args.wait_ready, args.json)
            except Exception as exc:
                results.append(VerifyResult("wait_ready", False, 0, repr(exc), error=repr(exc)))
            finally:
                client.close()
        if not results:
            for name, code, timeout in cases:
                results.append(run_case_isolated(name, code, timeout))
                time.sleep(0.4)
    payload = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "ok": all(item.ok for item in results),
        "passed": sum(1 for item in results if item.ok),
        "failed": sum(1 for item in results if not item.ok),
        "pipe_available_at_start": pipe_ok,
        "pipe_state_at_start": pipe_reason,
        "ready_state": ready_state,
        "destructive_cases_included": args.destructive,
        "results": [asdict(item) for item in results],
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"verify ok={payload['ok']} passed={payload['passed']} failed={payload['failed']} report={args.report}")
        for item in results:
            mark = "OK" if item.ok else "FAIL"
            print(f"[{mark}] {item.name}: {item.summary}")
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    mp.freeze_support()
    raise SystemExit(main())
