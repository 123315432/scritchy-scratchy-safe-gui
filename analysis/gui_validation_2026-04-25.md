# GUI / Safe Suite Validation 2026-04-25

## Scope
- Target process: `ScritchyScratchy.exe`, live PID observed: `44840`.
- CE MCP bridge: `\\.\pipe\CE_MCP_Bridge_v99`, `ping` OK and attached to Scritchy process.
- GUI entry: `D:\Code\_tmp\scritchy_il2cpp\scripts\scritchy_safe_gui.pyw`.
- Launcher: `D:\Code\_tmp\scritchy_il2cpp\start_scritchy_safe_gui.ps1`.

## Verified Safe Suite Actions
- `dump`: OK. Resolved GameAssembly, SaveData via Mono static, LayerOne, PerkManager, DebugTools, SuperJackpotManager, TicketShop, PrestigeManager, PlayerWallet, TicketProgressionManager.
- `dump_perks`: OK. Parsed 35 valid `activePerks` entries.
- `perk_boost_dryrun`: OK. Previewed runtime + `SaveData.boughtPrestigeUpgrades` synchronization, 32 entries would change, 0 missing save entries.
- `perk_boost_apply`: OK. Existing activePerks entries and existing `SaveData.boughtPrestigeUpgrades` dictionary entries were raised to 10 without adding dictionary entries or calling `ActivatePerk`.
- `free_dryrun`: OK. Patch sites currently show enabled bytes for `PlayerWallet.CanAfford`, `PlayerWallet.TrySubtract`, and `ShopPanel.CalculatePrice`.
- `sjp_max`: OK. SJP chance direct/AOB values verified at `99999.0`; 11 live symbol chance objects boosted.
- `rng_enable`: OK. `rng_control_v2.lua` reported already patched at current session address.
- `prestige_safe`: OK. Direct field writes only; `unsafeActivatePerk=false` and `perksActivated=0`.
- `tokens_safe`: OK. Direct `SaveData.tokens` write only; `setTokensCall=false`.
- `unlock_tickets_safe`: OK. Direct progression/gate writes only; `debugToolsCalls=false`.

## Persistence Verification
- Ticket progression remains persisted in `save.json`: 43 tickets, all `level=30`, minimum `xp=9999` from prior online persistence run.
- Economy remains persisted in `save.json`: `prestigeCount=99`, `prestigeCurrency=999999`, `currentAct=5`, `tokens=999999999.0`, `money=1e40`, `souls=999999`.
- Perk persistence is now verified: after `perk_boost_apply` plus `SaveData.Save()` call, `save.json` has 35 `boughtPrestigeUpgrades` entries, all value `10`, including `Super Lucky=10`.
- `superJackpotsGotten` currently still equals `jackpotsGotten` content with 17 entries; independent managed List restoration/expansion remains deferred.

## GUI Changes
- GUI now has auto attach enabled by default.
- On launch, GUI tries to connect to CE pipe; if pipe is unavailable it starts CE, then waits for game process.
- When `ScritchyScratchy.exe` appears, GUI auto-attaches through CE and keeps polling every 4 seconds.
- Added `一键启动/连接` button for CE + game + attach workflow.
- GUI action list remains whitelist-only through `scritchy_safe_suite.lua`; no arbitrary Lua input was added.

## Caveat
- The CE MCP named pipe behaves like a single active client in this environment. While Codex built-in MCP is actively holding the bridge connection, an external Python/GUI client may hit `WaitNamedPipe` timeout. Run the GUI normally after the Codex MCP interaction releases the pipe, or use the GUI as the primary client.

## Dangerous Paths Kept Disabled
- `PerkManager.ActivatePerk` is still avoided because prior live testing showed delayed `GameAssembly.dll` crash.
- DebugTools native calls remain avoided; safe unlock actions use field/container writes only.
- `free_enable` and `rng_enable` remain caution-marked because they patch executable code bytes, even though current isolated/live verification is OK.


## GUI Readability Update
- Default log output is now summarized. Full raw script output is hidden unless `显示详细调试输出` is checked.
- Ticket dropdown now uses Unity Localization `zh-Hans` table names from the game resources.
- Extracted localization map: `D:\Code\_tmp\scritchy_il2cpp\analysis\localization_zh_map.json`.
- Symbol names are not localized by the game; GUI uses raw `SymbolData.id` from game data.
- Symbol type labels use game enum names plus Chinese labels from the reverse mapping.
- Auto reapply now reports failed action keys in the log instead of only saying “保持已应用”.
- Mouse wheel scrolling is bound to the scrollable action/parameter panels and log area.
