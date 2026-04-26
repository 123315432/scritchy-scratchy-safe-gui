# GUI Integration 2026-04-25

## New GUI
- Path: D:\Code\_tmp\scritchy_il2cpp\scripts\scritchy_safe_gui.pyw
- Launcher: D:\Code\_tmp\scritchy_il2cpp\start_scritchy_safe_gui.ps1
- Desktop shortcut: C:\Users\69406\Desktop\Scritchy Safe GUI.lnk

## Design
- External Tk GUI.
- Connects to CE MCP bridge pipe `\\.\pipe\CE_MCP_Bridge_v99`.
- Can start CE and game if they are not running.
- Executes only whitelisted `SCRITCHY_SAFE_ACTION` through ce_scripts/scritchy_safe_suite.lua.
- Dangerous-ish actions show confirmation dialog.

## Connected actions
- Status/read-only: `runtime_status`, `dump`, `dump_perks`, `*_status`, `symbol_dump`.
- Persistent writes: `custom_save_fields`, `online_unlock`, `prestige_safe`, `tokens_safe`, `unlock_tickets_safe`, `bot_upgrade_apply`, `subscription_bot_apply`, `helper_upgrade_apply`, `ticket_progress_apply`, `loan_apply`, `loan_clear`, `single_perk_apply`.
- Runtime writes: `scratch_apply`, `subscription_runtime_apply`, `gadget_runtime_apply`, `experimental_runtime_apply`, `helper_state_apply`, `symbol_apply`.
- Code patches: `free_dryrun/free_enable/free_disable`, `rng_enable/rng_disable`, `sjp_v3`, `sjp_max`.
- All entries still go through `ce_scripts/scritchy_safe_suite.lua`; the GUI does not expose arbitrary Lua input.

## Old GUI review
- Old C:\Users\69406\Desktop\scratchy_gui.pyw has reusable Tk shell and CE pipe client.
- Old embedded Lua/AOB/timer logic should not be reused directly.
- New GUI follows safer action-dispatch model instead of arbitrary Lua generation.
