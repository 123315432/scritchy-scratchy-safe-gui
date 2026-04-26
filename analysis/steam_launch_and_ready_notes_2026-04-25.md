# Steam Launch / Ready-State Notes 2026-04-25

## 背景

- 目标：让 GUI/启动器像常规外挂启动链一样，游戏没开时能自动拉起游戏，游戏重启后无需手工重新找地址。
- 当前游戏 AppID：`3948120`，Steam manifest：`D:\steam1\steamapps\appmanifest_3948120.acf`。
- 当前入口：`start_scritchy_safe_gui.ps1`、`scripts/scritchy_safe_gui.pyw`、`scripts/scritchy_verify_api.py`。

## 踩过的坑

- 不能把 `ScritchyScratchy.exe` 当首选启动方式。直接 exe 启动时 `Player.log` 出现 `SteamAPI_Init() failed`，随后 CE/IL2CPP 侧可能拿不到 `SaveData`、`PlayerScratching` 等 class/instance。
- `SCRITCHY_GAME_EXE` 只能作为路径定位或最后兜底，不代表游戏已经按 Steam 上下文正常初始化。
- 游戏进程出现不等于存档就绪。刚启动时 `GameAssembly.dll` 可能已加载，但 `SaveData._current/current` 或 `SaveData+0x30 LayerOne` 仍可能是空。
- CE MCP bridge 在本机表现为单活动客户端。GUI、验证脚本、Codex MCP 同时抢 `\\.\pipe\CE_MCP_Bridge_v99` 时会出现 `WaitNamedPipe` timeout、busy 或句柄关闭噪声。
- CE 全局 Lua 缓存不能跨游戏 PID 使用。旧进程里的 `SCRITCHY_CACHED_SAVEDATA`、`SCRITCHY_CACHED_ScratchBot` 等地址在重启后会变成悬空指针。

## 已落地修复

- `scripts/scritchy_safe_gui.pyw`：
  - 新增 `GAME_STEAM_APP_ID = "3948120"`。
  - 新增 `find_steam_exe()`，支持 `STEAM_EXE`、`STEAM_ROOT`、注册表 SteamPath、常见 Steam 目录。
  - `start_game()` 优先执行 `steam.exe -applaunch 3948120`，再尝试 `steam://rungameid/3948120`，最后才直接 exe 兜底。
  - GUI 的“运行安全验证”会传 `--wait-ready 120`。
- `start_scritchy_safe_gui.ps1`：
  - 新增 `$steamAppId = '3948120'`、`Find-SteamExe`、`Start-ScritchyGame`。
  - 无游戏进程时优先通过 Steam AppID 启动，不再直接跑 exe。
- `scripts/scritchy_verify_api.py`：
  - 新增 `READY_LUA` 和 `--wait-ready SEC`。
  - 验证矩阵开始前等待 `getOpenedProcessID()>0`、`GameAssembly.dll`、`SaveData` static、`LayerOne` 都有效。
  - 报告新增 `ready_state`，方便后续确认本轮验证绑定的是哪个 PID 和哪组根指针。
- `ce_scripts/scritchy_safe_suite.lua`：
  - 已按 `getOpenedProcessID()` 检测 PID 变化并清理 `SCRITCHY_CACHED_SAVEDATA`、`SCRITCHY_SAVEDATA_STATIC_ADDR`、`SCRITCHY_SAVEDATA_CURRENT_OFFSET`、各类 `SCRITCHY_CACHED_*` 实例缓存。

## 本轮验证过程

- 直接 Steam 启动后观察到游戏进程：`ScritchyScratchy` PID `68936`，路径 `D:\steam1\steamapps\common\Scritchy Scratchy\ScritchyScratchy.exe`。
- 短矩阵命令：
  - `python .\scripts\scritchy_verify_api.py --shared-client --wait-ready 120 --case runtime_status --case dump --case gadget_runtime_dispatcher_restore --case helper_state_dispatcher_restore --case ticket_progress_dispatcher_restore --report .\analysis\auto_restart_verify_report.json`
- 短矩阵结果：`5/5` 通过，`ready_state=READY pid=68936 SaveData=0x181CB783700 LayerOne=0x181C0226630 source=mono_static`。
- 全量安全矩阵命令：
  - `python .\scripts\scritchy_verify_api.py --shared-client --wait-ready 120 --report .\analysis\gui_function_verify_report.json`
- 全量结果：先扩展到 `31/31`，再补 `free_patch_restore` 和 `symbol_dump` 后为 `33/33`，再补 `experimental_runtime_status/restore` 后为 `35/35`，再补 `symbol_type_dryrun` 和全字段 restore 覆盖后为 `36/36` 通过，并复制到 `analysis/gui_safe_verify_report.json`。
- 入口脚本回归：关闭 GUI/游戏后运行 `start_scritchy_safe_gui.ps1`，成功拉起 Steam 游戏 PID `69160` 和 GUI `pythonw.exe`。

## 后续维护规则

- 发布包 README 里不要建议用户直接运行 `ScritchyScratchy.exe`，除非明确说明这是兜底且可能导致 Steam 初始化失败。
- 新增写入型功能必须进 `scritchy_verify_api.py` 的写后恢复矩阵；同一个 dispatcher 能写的字段要尽量全覆盖，验证写测试值后恢复原值，不把现场存档改成测试数据。
- 新增运行时缓存必须纳入 PID 变化清理列表，否则跨重启会出现“第一次能改、第二次失效/崩”的问题。
- 代码补丁类脚本自己的 `_G` 状态也必须带 PID/base 校验；`free_tickets.lua` 之前只存 `state.patches`，跨进程后会把旧进程状态误当当前进程状态。
- 命令行验证默认加 `--wait-ready 120`；如果不加，刚启动游戏时失败不一定代表指针链失效。
- GUI 连接 CE 后可能占用 pipe；自动化验证要么复用 GUI 按钮，要么先关闭 GUI 再跑命令行。
- 运行时字段可能被游戏帧逻辑立刻消耗，例如 `electricFanChargeLeft` 写入 1 后马上变成 0.99；验证应优先看 dispatcher 写入回显，再用内存读做恢复校验，不能用过严 float 等值误报失败。
- `WaitNamedPipe 121` 是 CE 命名管道忙/单客户端占用，不是游戏崩。GUI 侧应重试并显示“CE 管道忙”，命令行验证前要关闭 GUI 或清理多余 `mcp_cheatengine.py` 副本。
- 实验运行时字段不进自动重应用循环：`ScratchBot.processingDuration` 和 `Mundo.paused` 都是流程控制字段，默认只手动读/写/验证恢复。订阅机器人运行时已单独覆盖 `SubscriptionBot.processingDuration +0x28` 和 `paused +0x58`，不要和 ScratchBot/Mundo 实验区混写。
- `toolSizeBacking +0x30` 现场原值可能是 `0`；恢复验证不能把下限夹到 `1`，否则会出现“写入成功但恢复不干净”的假修复。
- `UnityEngine.Time.timeScale` 有 RVA：`get_timeScale=0x26351F0`、`set_timeScale=0x26352E0`，但 CE Lua 里直接 `executeCode/executeCodeEx` 探测 getter 曾导致调用卡住并占住 pipe。连续失败后先换思路，不把 TimeScale 放进默认 GUI/验证；后续要用独立进程、短超时、失败自动重启 CE 的方式继续测。

## GUI 滚动坑

- Tk 的普通 `Frame` 不会自动滚动；`PanedWindow` 只负责左右分栏，也不会给子控件提供滚动。
- 之前只有日志区用了 `ScrolledText`，所以日志能滚，左侧功能页和右侧参数区都不能滚。
- 修复方式是在 Notebook 页和右侧参数区外面包 `Canvas + ttk.Scrollbar + inner Frame`，内容继续 pack 到 inner frame。
- 鼠标滚轮必须绑定到对应 Canvas，否则即使显示了滚动条，用户也会觉得“滚轮没反应”。

## 贷款清理实现记录

- 静态字段来自 `dump_il2cppdumper\dump.cs`：`LoanGroup.Save.id +0x10`、`index +0x18`、`loanNum +0x1C`、`severity +0x20`、`amount +0x28`。
- 持久层入口：`SaveData.loanCount +0xC0`，`PrestigeLayerOneData.loans +0x70`，后者是 `List<LoanGroup.Save>`。
- 安全实现只修改已有对象和 List size，不新增 `LoanGroup.Save` 托管对象，不调用 `LoanPanel.OnPayOff/DeactivateLoan` 之类原生函数。
- 默认验证方式是写测试值再恢复：loanCount、List size、第一条 loan 的 index/loanNum/severity/amount 都要回到原值。

## 单个已有 Perk 编辑记录

- 稳定结构：`PerkManager.activePerks +0x28` 是 `Dictionary<PerkType, Tuple<PerkData,int>>`，tuple item2 在 `tuple+0x18`，`PerkData.count` 在 `perkData+0x30`。
- 持久层：`SaveData.boughtPrestigeUpgrades +0x60`，字典 key 是 `PerkData.id` 字符串，value 在 entry `+0x10`。
- 安全边界：只编辑已经存在的 active entry 和已经存在的 save entry；不新增字典项，不伪造托管字符串/tuple/perkData，不调用 `ActivatePerk`。
- 现场坑点：历史存档里可能出现 tuple/save 与 `PerkData.count` 不一致；验证恢复时要按三处原值分别恢复，不能假设三处原始值相同。
