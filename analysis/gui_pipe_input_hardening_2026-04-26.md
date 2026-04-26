# GUI pipe/input hardening loop - 2026-04-26

## Changed
- Added one GUI-level CE lock so manual actions, status refresh, verify button, and auto reapply no longer compete for the single CE named pipe.
- Status refresh and auto reapply now skip a cycle instead of opening a second CE client while another action is running.
- Numeric GUI inputs now reject NaN/Inf and serialize finite numbers before embedding into Lua globals.
- Applying SJP, symbol weights, free-buy, or fixed-RNG no longer silently enables auto reapply; user has to tick the reapply checkbox explicitly.
- Launcher now resolves pythonw/pyw/py instead of assuming pythonw.exe is on PATH, and reports a visible error if Python cannot be found.

## Verified
- Closed existing project GUI windows before CLI validation to avoid pipe contention.
- Light probe: `python .\scripts\scritchy_verify_api.py --shared-client --wait-ready 180 --case runtime_status --case dump --case subscription_runtime_status --report .\analysis\loop_probe_after_gui_lock_20260426.json`
  - Result: 3/3 OK.
- Full default safe matrix: `python .\scripts\scritchy_verify_api.py --shared-client --wait-ready 180 --report .\analysis\gui_function_verify_report_after_gui_lock_20260426.json`
  - Result: 36/36 OK.
  - Ready line: `READY pid=35148 SaveData=0x2C444A46700 LayerOne=0x2C4386D7630 source=mono_static`.

## Pitfalls to avoid
- Do not run GUI, CLI verify, and MCP pipe tests at the same time; CE bridge behaves as a single active client.
- Do not auto-enable reapply after one patch success; repeated patch writes should be an explicit user setting.
- Do not pass Python `nan`, `inf`, or `1e309` through to Lua; CE/Lua memory writes become ambiguous.
- If testing the launcher by dot-sourcing it, it will execute the bottom-level start block and open a GUI. Use Parser.ParseFile for syntax-only checks.
