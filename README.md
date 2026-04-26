# Scritchy Scratchy Safe GUI

一个面向 Scritchy Scratchy 的本地 Cheat Engine 辅助 GUI。工具默认走白名单 Lua 动作，不向 CE 执行任意输入脚本；“验证全部功能”默认使用写入后恢复，不污染现场数值。

## 依赖

- Windows 10/11
- Python 3.12+（带 Tkinter）
- Cheat Engine
- CE MCP Bridge，默认命名管道：`\\.\pipe\CE_MCP_Bridge_v99`
- Python 包：`pip install -r requirements.txt`

## 启动

```powershell
powershell -ExecutionPolicy Bypass -File .\start_scritchy_safe_gui.ps1
```

默认会尝试启动 Cheat Engine、通过 Steam AppID `3948120` 启动游戏并打开 GUI。游戏或 CE 安装路径不在默认位置时，可设置 `STEAM_EXE`、`STEAM_ROOT`、`CHEAT_ENGINE_EXE`；`SCRITCHY_GAME_EXE` 只作为定位/兜底，不建议直接绕过 Steam 启动游戏。

已踩坑：直接运行 `ScritchyScratchy.exe` 可能触发 `SteamAPI_Init() failed`，随后 CE 侧会看到 `SaveData_class=nil`、`PlayerScratching_class=nil`，指针链和验证会失败。启动器和 GUI 按钮现在优先使用 `steam.exe -applaunch 3948120`，找不到 `steam.exe` 时才尝试 `steam://rungameid/3948120`。

## 已验证功能

当前安全验证报告：`analysis/gui_safe_verify_report.json`，2026-04-26 最近一次默认矩阵结果为 `36/36` 通过。

发布版 GUI 默认尽量留空输入框，避免误点后直接写大额金钱、清空贷款或拉满权重。需要改值时先点读取当前状态，再手动填写目标值；所有数值输入会拒绝 `NaN` / `Inf` 这类非有限数。

### 功能覆盖表

| 功能 | 状态 | GUI/验证入口 | 说明 |
|---|---|---|---|
| 状态/指针链读取 | 已验证 | `runtime_status` / `dump` | 只读读取 SaveData、LayerOne、PlayerScratching、PerkManager 等。 |
| 存档数值 | 已验证 | `custom_save_fields_restore` | 覆盖金钱、代币、灵魂、重生币、重生次数、章节；默认验证写测试值后恢复。 |
| 刮卡运行时参数 | 已验证 | `scratch_runtime_dispatcher_restore` | 覆盖粒子速度、鼠标速度、检测频率、幸运值、衰减和工具字段；写后恢复。 |
| 刮刮机器人升级 | 已验证 | `bot_upgrade_dispatcher_restore` | 写 `LayerOne.upgradeDataDict` 里的已有升级计数并恢复。 |
| 订阅机器人升级 | 已验证 | `subscription_bot_dispatcher_restore` | 覆盖 `Subscription Bot` 和 `Buying Speed`。 |
| 订阅机器人运行时 | 已验证 | `subscription_runtime_dispatcher_restore` | 覆盖处理时长、最大票数、暂停标记、购买速度倍率；当前票仍只读。 |
| 辅助道具持久升级 | 已验证 | `helper_upgrade_dispatcher_restore` | 覆盖风扇、蒙多、法术书、计时器、Warp Speed 等已有升级计数。 |
| 单票等级/经验 | 已验证 | `ticket_progress_dispatcher_restore` | 只改选中一张票的 `level/xp`，不补 jackpot 列表。 |
| 贷款清理 | 已验证 | `loan_state_dispatcher_restore` | 覆盖 `SaveData.loanCount`、`LayerOne.loans` 列表长度和已有 `LoanGroup.Save` 字段；不新增对象。 |
| 辅助状态救援 | 已验证 | `helper_state_dispatcher_restore` | 覆盖电扇/计时器充能、风扇暂停、蒙多/垃圾桶死亡标记。 |
| 辅助道具运行时倍率 | 已验证 | `gadget_runtime_dispatcher_restore` | 覆盖煮蛋计时器、风扇、蒙多、刮刮机器人、法术书倍率字段，默认写后恢复。 |
| 刮刮机器人基础运行时 | 已验证 | `gadget_runtime_dispatcher_restore` | 覆盖 `ScratchBot.capacity +0xC4`、`strength +0xC8`，以及速度/额外容量/额外强度字段；写后恢复。 |
| 实验运行时字段 | 已验证恢复 | `experimental_runtime_dispatcher_restore` | 覆盖 `ScratchBot.processingDuration` 和 `Mundo.paused`，只改当前进程，不进自动重应用。 |
| 单个已有能力编辑 | 已验证 | `single_perk_restore` | 只改已有 `activePerks` / `boughtPrestigeUpgrades` 条目；不新增能力，不调用 `ActivatePerk`。 |
| 自动化能力 | 已验证只读 | `automation_perks_status` | 只读取/处理已有 `Fully Automated` / `HandsOff` 条目，不伪造对象。 |
| 符号权重 | 已验证 | `symbol_dryrun` / `symbol_type_dryrun` / `symbol_write_restore` | 支持按票、按符号、按类别、按幸运等级控制权重。 |
| RNG 固定 | 已验证恢复 | `rng_patch_restore` | 验证时启用补丁后立即卸载恢复原指令。 |
| 免费购买 | 已验证恢复 | `free_dryrun` / `free_patch_restore` | 代码补丁；默认验证启用后立即卸载恢复原指令，GUI 仍需手动启停。 |
| SJP 权重 | 已接入，危险项 | `sjp_max` / `sjp_v3` | 会改当前进程权重/补丁点，默认安全验证不跑。 |
| 全票进度解锁 | 已接入，持久项 | `online_unlock` | 会推进票等级/经验和 Jackpot 列表，默认安全验证不跑。 |
| DebugTools / ActivatePerk | 禁用 | 无默认入口 | 原生调用 ABI 未完全验证，历史上 `ActivatePerk` 有崩溃风险。 |

默认 GUI 验证覆盖：

- 运行时状态读取：存档、钱包、刮卡、工具、超级头奖状态。
- 存档数值写入恢复：金钱、代币、灵魂、重生币、重生次数、章节先写测试值，再恢复原值。
- 刮卡运行时写入恢复：粒子速度、鼠标速度、每秒检测次数、幸运值、幸运衰减、工具强度/尺寸/尺寸衰减先写测试值，再恢复原值。
- 刮刮机器人持久升级写入恢复：解锁、速度、容量、力度按当前值回滚。
- 订阅机器人持久升级写入恢复：订阅机器人、购买速度按当前值回滚。
- 订阅机器人运行时写入恢复：处理时长、最大票数、暂停标记、购买速度倍率按当前值回滚。
- 辅助道具持久升级写入恢复：风扇、蒙多、法术书、煮蛋计时器、Warp Speed 等已有升级计数按当前值回滚。
- 单票进度写入恢复：选中刮刮卡的等级、经验先写测试值，再恢复原值。
- 贷款字段写入恢复：贷款计数、贷款列表长度、第一条贷款字段先写测试值，再恢复原值。
- 辅助状态救援写入恢复：电扇/计时器充能、风扇暂停、蒙多/垃圾桶死亡标记先写测试值，再恢复原值。
- 辅助道具运行时写入恢复：煮蛋计时器、风扇、蒙多、刮刮机器人、法术书倍率按当前值回滚；其中 `ScratchBot.capacity`、`ScratchBot.strength` 也会写测试值后恢复。
- 实验运行时写入恢复：刮刮机器人处理时长、蒙多运行时暂停标记先写测试值，再恢复原值。
- 单个已有能力写入恢复：选定已有能力的运行时 tuple、PerkData.count、存档字典值先写测试值，再恢复原值。
- 自动化能力状态读取：只处理已有 `Fully Automated` / `HandsOff` 条目，不伪造对象。
- 免费购买补丁：验证时启用 `PlayerWallet.CanAfford` / `TrySubtract` / `ShopPanel.CalculatePrice` 补丁后立即卸载恢复。
- 符号几率读取：默认矩阵会读取 `Lucky Cat` 当前符号表，确认运行时读取链路有效。
- 符号几率：支持精确符号 dryrun、按类别 dryrun；真实写入验证会读取原值、写测试值、再恢复原值。
- RNG 补丁：验证时启用后立即卸载恢复原始指令字节。

需要显式运行的危险/持久项：

- `python .\scripts\scritchy_verify_api.py --shared-client --destructive`
- 该模式会额外跑旧式持久写入项，例如在线解锁、SJP 最大权重、固定写入金钱/代币等；发布给普通用户时不建议默认使用。

## 未接入路线

下面是已静态定位、但还没有纳入默认 GUI/验证矩阵的候选。发版时不要把它们写成“已验证”。

- `UnityEngine.Time.timeScale`：全局倍速，风险高，应放实验区并单独恢复验证。
- `PrestigeLayerOneData.machineProcessingTimeLeft +0x84`：低风险候选，指向 `SaveData.layerOne +0x84`，但属于机器流程倒计时/存档字段，尚未纳入默认写入矩阵。
- `TheMachine.processingDuration +0x20`：实验运行时候选，实例生命周期跟场景相关，尚未纳入默认写入矩阵。
- `MachineTierData.bonusIncome +0x20`：收益倍率数据已静态定位，但 live tier 对象归属和恢复目标尚未验证，暂不写入。

## 符号概率

“读取这张刮刮卡当前几率”默认优先读取 `analysis/SymbolData.json` 本地缓存，速度接近秒开；需要确认 live 内存时点“强制实时读取”。

选择不同刮刮卡后，“符号名字”下拉只显示该卡自己的符号。表格里的 `L0` 到 `L6` 是不同幸运等级下的权重，数字越大越容易出现，不是百分比。

如果清空“符号名字”，再选择“符号类别”，会对当前刮刮卡内同类别符号批量应用；`幸运等级索引=-1` 表示写全部等级槽。

## 发布包建议

发布时至少保留：

- `scripts/scritchy_safe_gui.pyw`
- `scripts/scritchy_verify_api.py`
- `ce_scripts/`
- `analysis/TicketData.json`
- `analysis/SymbolData.json`
- `analysis/localization_zh_map.json`
- `analysis/UpgradeData.json`
- `analysis/gui_function_verify_report.json`
- `analysis/gui_safe_verify_report.json`
- `start_scritchy_safe_gui.ps1`
- `requirements.txt`
- `README.md`

不要把个人分析产物、dump、临时队列、游戏本体、截图、聊天导出或第三方反编译器二进制一起提交。`.gitignore` 已默认忽略这些内容。

## 验证命令

```powershell
python .\scripts\scritchy_verify_api.py --shared-client --wait-ready 120
```

默认报告写入 `analysis/gui_function_verify_report.json`。如果只想复测某个功能：

```powershell
python .\scripts\scritchy_verify_api.py --shared-client --wait-ready 120 --case symbol_write_restore
```

验证前会等待 `GameAssembly.dll`、`SaveData._current/current` 和 `LayerOne` 初始化完成，避免游戏刚启动时把“存档还没加载”误判成指针链失效。CE bridge 在当前环境表现为单活动客户端；GUI 开着时可能占用管道，跑命令行验证前先关 GUI 或让 GUI 里的验证按钮执行。

重启游戏后必须重新定位运行时对象。`scritchy_safe_suite.lua` 会按 `getOpenedProcessID()` 检测 PID 变化并清理 `SCRITCHY_CACHED_*`，不要把上一次进程里的指针地址当成稳定地址写进文档或配置。

GUI 的 CE 交互现在走单个界面锁：手动动作、后台状态刷新、安全验证、自动重应用不会同时抢 `\\.\pipe\CE_MCP_Bridge_v99`。安全验证期间不要点其它动作；GUI 会暂停其它 CE 操作并在日志里输出简要进度。

GUI 的自动重应用只默认覆盖运行时参数；持久存档项需要额外勾选，实验运行时不进自动重应用循环。SJP 权重、符号权重、免费购买补丁、固定 RNG 补丁不会因为手动应用成功就自动勾选重应用，必须显式勾选对应子项。自动重应用失败会在日志里按 action 输出失败项。
