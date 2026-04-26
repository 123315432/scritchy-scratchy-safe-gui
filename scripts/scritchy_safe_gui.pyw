#!/usr/bin/env python3
from __future__ import annotations
import json
import os
import re
import struct
import subprocess
import sys
import threading
import time
import tkinter as tk
import winreg
from dataclasses import dataclass
from pathlib import Path
from tkinter import messagebox, scrolledtext, ttk

import win32file
import win32pipe

ROOT_DIR = Path(__file__).resolve().parents[1]
PIPE_NAME = r"\\.\pipe\CE_MCP_Bridge_v99"
GAME_EXE = "ScritchyScratchy.exe"
GAME_STEAM_APP_ID = "3948120"
CE_SCRIPTS = ROOT_DIR / "ce_scripts"
SAFE_SUITE = CE_SCRIPTS / "scritchy_safe_suite.lua"
DATA_DIR = ROOT_DIR / "analysis"
SYMBOL_DATA_JSON = DATA_DIR / "SymbolData.json"
LOCALIZATION_JSON = DATA_DIR / "localization_zh_map.json"
VERIFY_API = ROOT_DIR / "scripts" / "scritchy_verify_api.py"
VERIFY_REPORT = DATA_DIR / "gui_function_verify_report.json"


def env_path(name: str) -> Path | None:
    value = os.environ.get(name)
    if not value:
        return None
    path = Path(value).expanduser()
    return path if path.exists() else None


def steam_roots() -> list[Path]:
    roots: list[Path] = []
    env_root = env_path("STEAM_ROOT")
    if env_root:
        roots.append(env_root)
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
            steam_path, _ = winreg.QueryValueEx(key, "SteamPath")
            if steam_path:
                roots.append(Path(str(steam_path)))
    except OSError:
        pass
    roots.extend([
        Path(r"C:\Program Files (x86)\Steam"),
        Path(r"C:\Program Files\Steam"),
        Path(r"D:\Steam"),
        Path(r"D:\steam1"),
    ])
    unique = []
    seen = set()
    for root in roots:
        try:
            resolved = root.expanduser().resolve()
        except OSError:
            resolved = root.expanduser()
        key = str(resolved).lower()
        if key not in seen and resolved.exists():
            seen.add(key)
            unique.append(resolved)
    return unique


def parse_steam_libraryfolders(path: Path) -> list[Path]:
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8", errors="ignore")
    libraries = []
    for raw in re.findall(r'"path"\s+"([^"]+)"', text):
        candidate = Path(raw.replace("\\\\", "\\"))
        if candidate.exists():
            libraries.append(candidate)
    return libraries


def find_game_path() -> Path | None:
    env_game = env_path("SCRITCHY_GAME_EXE")
    if env_game:
        return env_game
    candidates: list[Path] = []
    for root in steam_roots():
        libraries = [root, *parse_steam_libraryfolders(root / "steamapps" / "libraryfolders.vdf")]
        for library in libraries:
            candidates.append(library / "steamapps" / "common" / "Scritchy Scratchy" / GAME_EXE)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def find_steam_exe() -> Path | None:
    env_steam = env_path("STEAM_EXE")
    if env_steam:
        return env_steam
    for root in steam_roots():
        candidate = root / "steam.exe"
        if candidate.exists():
            return candidate
    return None


def find_ce_path() -> Path | None:
    env_ce = env_path("CHEAT_ENGINE_EXE")
    if env_ce:
        return env_ce
    for candidate in (
        Path(r"C:\Program Files\Cheat Engine\cheatengine-x86_64.exe"),
        Path(r"C:\Program Files (x86)\Cheat Engine\cheatengine-x86_64.exe"),
    ):
        if candidate.exists():
            return candidate
    return None

TICKET_DISPLAY = {
    "日常工作": "Day Job",
    "成双成对": "Two Win",
    "三连胜出": "Mini Scratch",
    "苹果树": "Apple Tree",
    "速配赢家": "Quick Cash",
    "好运喵喵": "Lucky Cat",
    "放手一搏": "Final Chance",
    "沙中埋钱": "Sand Dollars",
    "挠挠我的背": "Scratch My Back",
    "蛇眼": "Snake Eyes",
    "炸弹": "The Bomb",
    "最终机会 v2": "Final Chance_2",
    "银行劫案": "Bank Break",
    "圣诞节倒计时": "Xmas Countdown",
    "旧货店": "Thrift Store",
    "采摘浆果": "Berry Picking",
    "最终机会 v3": "Final Chance_3",
    "不给糖就捣蛋": "Trick or Treat",
    "老虎机": "Slot Machine",
    "去月球": "To the Moon",
    "加速包": "Booster Pack",
    "最终机会 v4": "Final Chance_4",
}

SYMBOL_TYPES = {
    "按符号名字": "",
    "坏符号（推断）/ Bad": "-1",
    "空符号（推断）/ Dud": "0",
    "小奖（推断）/ Small": "1",
    "头奖 / Jackpot": "2",
    "超级头奖 / Super Jackpot": "3",
    "倍率（推断）/ Multiplier": "4",
    "自毁（推断）/ Self Destruct": "5",
}

SYMBOL_WORDS = {
    "Signature": "签名", "Clean": "干净盘子", "Broken": "破盘子", "Gold": "金", "Golden": "金色",
    "Ring": "戒指", "Lunch": "午餐", "Money": "零钱", "Bill": "钞票", "Bills": "一叠钞票",
    "Bag": "袋子", "Pennies": "硬币", "Purse": "钱包", "Coin": "硬币", "Stack": "一摞",
    "Worm": "虫子", "Leaf": "树叶", "Bee": "蜜蜂", "Flower": "花", "Green": "绿色",
    "Red": "红色", "Apple": "苹果", "Fishbone": "鱼刺", "Fish": "鱼", "Pink": "粉色",
    "Paw": "爪", "Print": "印", "Diamond": "钻石", "Plastic": "塑料", "Jellyfish": "水母",
    "Turtle": "乌龟", "Eye": "眼睛", "Eyes": "眼睛", "Snake": "蛇", "Dice": "骰子",
    "Bomb": "炸弹", "Light": "灯", "Vault": "保险库", "Key": "钥匙", "Lock": "锁",
    "Present": "礼物", "Tree": "树", "Star": "星星", "Moth": "蛾子", "Shirt": "衬衫",
    "Pants": "裤子", "Berry": "浆果", "Blueberry": "蓝莓", "Gooseberry": "醋栗", "Moon": "月亮",
    "Rocket": "火箭", "Booster": "加速包", "Candy": "糖果", "Pumpkin": "南瓜", "Skull": "骷髅",
    "Slot": "老虎机", "Cherry": "樱桃", "Bar": "BAR", "Seven": "7", "Mult": "倍率",
    "SelfDestruct": "自毁", "Death": "死亡", "Explosion": "爆炸", "Coal": "煤炭", "Bell": "铃铛",
    "Clover": "四叶草", "Coral": "珊瑚", "Crab": "螃蟹", "Chicken": "鸡", "Chocolate": "巧克力",
    "Caramel": "焦糖", "Corn": "玉米", "Dino": "恐龙", "Egg": "蛋", "Footprint": "脚印",
    "Necklace": "项链", "Plate": "盘子", "Market": "市场", "Crash": "崩盘", "Everything": "全部",
}

@dataclass
class Action:
    key: str
    label: str
    description: str
    caution: bool = False

ACTION_SECTIONS = [
    ("快捷动作", "常用状态读取、资源/进度写入和补丁开关；危险项会用红色按钮标出。", [
        ("状态检查", [
            Action("runtime_status", "读取运行时总状态", "只读汇总：资源、当前票、刮卡参数、超级头奖状态"),
            Action("dump", "刷新底层对象状态", "只读取当前 SaveData、LayerOne、票进度、管理器指针，不写入"),
            Action("dump_perks", "查看当前能力列表", "只读取当前已激活能力，不改数值"),
        ]),
        ("进度和资源", [
            Action("online_unlock", "解锁全部刮刮卡进度", "改 SaveData：43 张票 level=30 / xp=9999，并补资源门槛"),
            Action("prestige_safe", "拉满重生/资源进度", "改 SaveData/LayerOne：重生99、代币999999999、钱1e40、灵魂999999、章节5"),
            Action("tokens_safe", "写入代币 999999999", "只改 SaveData.tokens，不调用游戏危险函数"),
            Action("unlock_tickets_safe", "打开刮刮卡入口", "改当前章节和解锁门槛，让票入口满足条件"),
        ]),
        ("能力等级", [
            Action("perk_boost_dryrun", "预览已有能力升 10 级", "只扫描当前能力和存档能力，不写入"),
            Action("perk_boost_apply", "把已有能力升到 10 级", "同步改当前 PerkManager 和 SaveData 里已有能力等级，需要确认", True),
            Action("automation_perks_status", "查看自动化能力状态", "只读查看 HandsOff(19) / FullyAutomated(36) 是否已有 active entry"),
            Action("automation_perks_apply", "开启已有自动化能力", "只改已有 HandsOff/FullyAutomated entry；不新增、不调用 ActivatePerk", True),
        ]),
    ]),
    ("运行时 / 临时补丁", "只改当前游戏进程内存或代码；大多数重启游戏后恢复，需要重新开启。", [
        ("概率和抽奖", [
            Action("sjp_v3", "提高超级头奖概率（保守）", "改当前进程里的超级头奖判断/权重，重启游戏会恢复", True),
            Action("sjp_max", "超级头奖概率拉满", "把当前进程超级头奖权重写得很高，重启游戏会恢复", True),
            Action("rng_enable", "固定抽奖结果为第 1 项", "修改当前进程随机选择逻辑，属于代码补丁，需要确认", True),
            Action("rng_disable", "恢复抽奖随机逻辑", "撤销当前进程里的固定随机补丁"),
        ]),
        ("免费购买", [
            Action("free_dryrun", "检查免费购买补丁点", "只检查当前版本能不能安全启用免费购买"),
            Action("free_enable", "启用免费刮刮卡/商店", "补丁当前进程支付、扣费、价格计算；重启游戏会恢复，需要确认", True),
            Action("free_disable", "关闭免费购买补丁", "撤销当前进程里的免费购买补丁"),
        ]),
    ]),
]

class CEClient:
    def __init__(self):
        self.handle = None
        self.req_id = 0
        self.lock = threading.RLock()

    def connect(self, timeout_ms=8000):
        with self.lock:
            if self.handle:
                return
            deadline = time.time() + timeout_ms / 1000.0
            last_error = None
            while time.time() < deadline:
                try:
                    win32pipe.WaitNamedPipe(PIPE_NAME, 250)
                    self.handle = win32file.CreateFile(PIPE_NAME, win32file.GENERIC_READ | win32file.GENERIC_WRITE, 0, None, win32file.OPEN_EXISTING, 0, None)
                    return
                except Exception as exc:
                    last_error = exc
                    time.sleep(0.15)
            raise TimeoutError(f"CE 管道暂时忙或未就绪：{last_error}")

    def close(self):
        with self.lock:
            handle = self.handle
            self.handle = None
        if handle:
            try:
                win32file.CloseHandle(handle)
            except Exception:
                pass

    def call(self, method: str, params: dict | None = None) -> dict:
        if params is None:
            params = {}
        self.req_id += 1
        data = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": self.req_id}).encode("utf-8")
        try:
            win32file.WriteFile(self.handle, struct.pack("<I", len(data)) + data)
            _, hdr = win32file.ReadFile(self.handle, 4)
            size = struct.unpack("<I", hdr)[0]
            _, body = win32file.ReadFile(self.handle, size)
            return json.loads(body.decode("utf-8"))
        except Exception:
            self.close()
            raise

    def lua(self, code: str) -> dict:
        with self.lock:
            self.connect()
            try:
                return self.call("evaluate_lua", {"code": code}).get("result", {})
            finally:
                self.close()

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Scritchy Scratchy 工具箱")
        self.geometry("1320x800")
        self.configure(bg="#f6f7fb")
        self.client = CEClient()
        self.status = tk.StringVar(value="启动中：等待 CE / 游戏")
        self.auto_attach_enabled = tk.BooleanVar(value=True)
        self.verbose_log = tk.BooleanVar(value=False)
        self.keep_values_enabled = tk.BooleanVar(value=False)
        self.keep_persistent_enabled = tk.BooleanVar(value=False)
        self.keep_sjp_enabled = tk.BooleanVar(value=False)
        self.keep_symbol_enabled = tk.BooleanVar(value=False)
        self.keep_free_enabled = tk.BooleanVar(value=False)
        self.keep_rng_enabled = tk.BooleanVar(value=False)
        self.ticket_var = tk.StringVar(value="好运喵喵")
        self.symbol_name_var = tk.StringVar(value="")
        self.symbol_type_var = tk.StringVar(value="超级头奖 / Super Jackpot")
        self.weight_var = tk.StringVar(value="")
        self.luck_index_var = tk.StringVar(value="-1")
        self.sjp_chance_var = tk.StringVar(value="")
        self.money_var = tk.StringVar(value="")
        self.tokens_var = tk.StringVar(value="")
        self.souls_var = tk.StringVar(value="")
        self.prestige_currency_var = tk.StringVar(value="")
        self.prestige_count_var = tk.StringVar(value="")
        self.act_var = tk.StringVar(value="")
        self.unlock_level_var = tk.StringVar(value="")
        self.unlock_xp_var = tk.StringVar(value="")
        self.scratch_particle_speed_var = tk.StringVar(value="")
        self.mouse_velocity_max_var = tk.StringVar(value="")
        self.scratch_checks_var = tk.StringVar(value="")
        self.scratch_luck_var = tk.StringVar(value="")
        self.luck_reduction_var = tk.StringVar(value="")
        self.tool_strength_var = tk.StringVar(value="")
        self.tool_size_var = tk.StringVar(value="")
        self.tool_size_reduction_var = tk.StringVar(value="")
        self.bot_unlock_var = tk.StringVar(value="")
        self.bot_speed_var = tk.StringVar(value="")
        self.bot_capacity_var = tk.StringVar(value="")
        self.bot_strength_var = tk.StringVar(value="")
        self.sub_bot_unlock_var = tk.StringVar(value="")
        self.buying_speed_var = tk.StringVar(value="")
        self.sub_processing_duration_var = tk.StringVar(value="")
        self.sub_max_ticket_count_var = tk.StringVar(value="")
        self.sub_paused_var = tk.StringVar(value="")
        self.sub_processing_speed_var = tk.StringVar(value="")
        self.helper_fan_var = tk.StringVar(value="")
        self.helper_fan_speed_var = tk.StringVar(value="")
        self.helper_fan_battery_var = tk.StringVar(value="")
        self.helper_mundo_var = tk.StringVar(value="")
        self.helper_mundo_speed_var = tk.StringVar(value="")
        self.helper_spell_book_var = tk.StringVar(value="")
        self.helper_spell_charge_var = tk.StringVar(value="")
        self.helper_egg_timer_var = tk.StringVar(value="")
        self.helper_timer_capacity_var = tk.StringVar(value="")
        self.helper_timer_charge_var = tk.StringVar(value="")
        self.helper_warp_speed_var = tk.StringVar(value="")
        self.progress_ticket_var = tk.StringVar(value="好运喵喵")
        self.progress_level_var = tk.StringVar(value="")
        self.progress_xp_var = tk.StringVar(value="")
        self.loan_count_var = tk.StringVar(value="")
        self.loan_list_size_var = tk.StringVar(value="")
        self.loan_index_var = tk.StringVar(value="")
        self.loan_num_var = tk.StringVar(value="")
        self.loan_severity_var = tk.StringVar(value="")
        self.loan_amount_var = tk.StringVar(value="")
        self.electric_fan_charge_var = tk.StringVar(value="")
        self.fan_paused_var = tk.StringVar(value="")
        self.egg_timer_charge_left_var = tk.StringVar(value="")
        self.mundo_dead_var = tk.StringVar(value="")
        self.trash_can_dead_var = tk.StringVar(value="")
        self.eggtimer_capacity_var = tk.StringVar(value="")
        self.eggtimer_charge_var = tk.StringVar(value="")
        self.eggtimer_mult_var = tk.StringVar(value="")
        self.fan_capacity_var = tk.StringVar(value="")
        self.fan_charge_var = tk.StringVar(value="")
        self.fan_speed_var = tk.StringVar(value="")
        self.mundo_claim_speed_var = tk.StringVar(value="")
        self.scratchbot_speed_mult_var = tk.StringVar(value="")
        self.scratchbot_extra_speed_var = tk.StringVar(value="")
        self.scratchbot_extra_capacity_var = tk.StringVar(value="")
        self.scratchbot_extra_strength_var = tk.StringVar(value="")
        self.spellbook_recharge_var = tk.StringVar(value="")
        self.scratchbot_processing_duration_var = tk.StringVar(value="")
        self.mundo_paused_runtime_var = tk.StringVar(value="")
        self.single_perk_target_var = tk.StringVar(value="")
        self.single_perk_count_var = tk.StringVar(value="")
        self.localization = self.load_localization()
        self.symbol_data = self.load_symbol_cache()
        self.symbols_by_ticket = self.index_symbols_by_ticket(self.symbol_data)
        self.symbol_combo = None
        self.last_attached_pid = None
        self.busy = False
        self.keep_busy = False
        self.scroll_regions = []
        self._build()
        self.bind_all("<MouseWheel>", self.route_mousewheel)
        self.bind_all("<Button-4>", self.route_mousewheel)
        self.bind_all("<Button-5>", self.route_mousewheel)
        self.after(300, lambda: self.run_bg(self.bootstrap))
        self.after(1200, self.refresh_status)
        self.after(5000, self.keep_values_loop)

    def _build(self):
        self._setup_styles()

        hero = ttk.Frame(self, style="Hero.TFrame")
        hero.pack(fill="x", padx=12, pady=(12, 8))
        ttk.Label(hero, text="Scritchy Scratchy 工具箱", style="HeroTitle.TLabel").pack(side="left", padx=14, pady=9)
        ttk.Label(hero, textvariable=self.status, style="HeroStatus.TLabel").pack(side="left", padx=14)
        ttk.Button(hero, text="一键准备", style="Accent.TButton", command=lambda: self.run_bg(self.bootstrap)).pack(side="right", padx=6, pady=8)
        ttk.Button(hero, text="读取状态", command=lambda: self.run_bg(self.dump_runtime_status)).pack(side="right", padx=4, pady=8)
        ttk.Button(hero, text="运行安全验证", style="Accent.TButton", command=lambda: self.run_bg(self.run_verify_api)).pack(side="right", padx=4, pady=8)
        ttk.Button(hero, text="打开安全验证报告", command=self.open_verify_report).pack(side="right", padx=4, pady=8)
        ttk.Button(hero, text="连接游戏", command=lambda: self.run_bg(self.attach_game)).pack(side="right", padx=4, pady=8)
        ttk.Button(hero, text="启动游戏", command=self.start_game).pack(side="right", padx=4, pady=8)
        ttk.Button(hero, text="启动 CE", command=self.start_ce).pack(side="right", padx=4, pady=8)
        ttk.Button(hero, text="清屏", command=lambda: self.log_box.delete("1.0", "end")).pack(side="right", padx=4, pady=8)

        opts = ttk.Frame(self, style="Panel.TFrame")
        opts.pack(fill="x", padx=12)
        ttk.Checkbutton(opts, text="游戏开了就自动连接", variable=self.auto_attach_enabled).pack(side="left", padx=8, pady=6)
        ttk.Checkbutton(opts, text="显示详细调试输出", variable=self.verbose_log).pack(side="left", padx=12, pady=6)
        ttk.Checkbutton(opts, text="自动重应用运行时项", variable=self.keep_values_enabled).pack(side="left", padx=12, pady=6)
        ttk.Checkbutton(opts, text="包含持久存档项", variable=self.keep_persistent_enabled).pack(side="left", padx=12, pady=6)
        ttk.Label(opts, text="默认只周期重写运行时倍率/参数；勾“包含持久存档项”才会重写金钱、升级、单票进度。", style="Hint.TLabel").pack(side="left", padx=12)

        keep_opts = ttk.Frame(self, style="Panel.TFrame")
        keep_opts.pack(fill="x", padx=12, pady=(2, 0))
        ttk.Label(keep_opts, text="补丁重应用子项：", style="Hint.TLabel").pack(side="left", padx=(8, 2), pady=3)
        ttk.Checkbutton(keep_opts, text="SJP 权重", variable=self.keep_sjp_enabled).pack(side="left", padx=8, pady=3)
        ttk.Checkbutton(keep_opts, text="当前符号几率", variable=self.keep_symbol_enabled).pack(side="left", padx=8, pady=3)
        ttk.Checkbutton(keep_opts, text="免费购买补丁", variable=self.keep_free_enabled).pack(side="left", padx=8, pady=3)
        ttk.Checkbutton(keep_opts, text="固定 RNG 补丁", variable=self.keep_rng_enabled).pack(side="left", padx=8, pady=3)
        ttk.Label(keep_opts, text="建议先手动应用/启用一次，再勾自动重应用。", style="Hint.TLabel").pack(side="left", padx=12, pady=3)

        paned = ttk.PanedWindow(self, orient="horizontal")
        paned.pack(fill="both", expand=True, padx=12, pady=10)
        left = ttk.Frame(paned, style="Panel.TFrame")
        right = ttk.Frame(paned, style="Panel.TFrame")
        paned.add(left, weight=1)
        paned.add(right, weight=2)

        section_tabs = ttk.Notebook(left)
        section_tabs.pack(fill="both", expand=True, padx=2, pady=2)
        for section_name, section_desc, groups in ACTION_SECTIONS:
            section_shell, section_frame = self.make_scrollable(section_tabs)
            section_tabs.add(section_shell, text=section_name)
            ttk.Label(section_frame, text=section_desc, style="SectionHint.TLabel", wraplength=430).pack(fill="x", padx=10, pady=(10, 6))
            for group_name, actions in groups:
                box = ttk.LabelFrame(section_frame, text=group_name, style="Card.TLabelframe")
                box.pack(fill="x", padx=8, pady=7)
                for action in actions:
                    btn_style = "Danger.TButton" if action.caution else "Action.TButton"
                    ttk.Button(box, text=action.label, style=btn_style, command=lambda a=action: self.run_action(a)).pack(fill="x", padx=10, pady=(6, 2))
                    color_style = "DangerHint.TLabel" if action.caution else "Hint.TLabel"
                    ttk.Label(box, text=action.description, style=color_style, wraplength=410).pack(anchor="w", padx=12, pady=(0, 6))

        right_form_shell, right_form = self.make_scrollable(right)
        right_form_shell.pack(fill="both", expand=True, padx=2, pady=(2, 8))

        custom_box = ttk.LabelFrame(right_form, text="手动填写存档数值：游戏开着直接写", style="Card.TLabelframe")
        custom_box.pack(fill="x", pady=(0, 8))
        custom = ttk.Frame(custom_box)
        custom.pack(fill="x", padx=8, pady=6)
        custom_fields = [
            ("金钱", self.money_var), ("代币", self.tokens_var), ("灵魂", self.souls_var),
            ("重生币", self.prestige_currency_var), ("重生次数", self.prestige_count_var), ("章节", self.act_var),
            ("票等级", self.unlock_level_var), ("票经验", self.unlock_xp_var),
        ]
        for index, (label, var) in enumerate(custom_fields):
            row = index // 4
            col = (index % 4) * 2
            ttk.Label(custom, text=label).grid(row=row, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(custom, textvariable=var, width=14).grid(row=row, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(custom, text="只应用金钱", command=lambda: self.run_custom_save_fields(only="money")).grid(row=2, column=0, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Button(custom, text="只应用代币", command=lambda: self.run_custom_save_fields(only="tokens")).grid(row=2, column=2, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Button(custom, text="应用全部填写项", command=lambda: self.run_custom_save_fields()).grid(row=2, column=4, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Button(custom, text="按等级/经验解锁全部票", command=lambda: self.run_custom_unlock()).grid(row=2, column=6, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Label(custom_box, text="这是存档字段写入：留空表示不改；游戏可能自动保存。勾“包含持久存档项”后才会周期性重写这些值。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        scratch_box = ttk.LabelFrame(right_form, text="临时刮卡参数：只改当前进程", style="Card.TLabelframe")
        scratch_box.pack(fill="x", pady=(0, 8))
        scratch = ttk.Frame(scratch_box)
        scratch.pack(fill="x", padx=8, pady=6)
        scratch_fields = [
            ("粒子速度", self.scratch_particle_speed_var), ("鼠标速度上限", self.mouse_velocity_max_var), ("每秒检测次数", self.scratch_checks_var),
            ("刮卡幸运", self.scratch_luck_var), ("幸运衰减", self.luck_reduction_var), ("工具强度", self.tool_strength_var),
            ("工具尺寸", self.tool_size_var), ("尺寸衰减", self.tool_size_reduction_var),
        ]
        for index, (label, var) in enumerate(scratch_fields):
            row = index // 4
            col = (index % 4) * 2
            ttk.Label(scratch, text=label).grid(row=row, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(scratch, textvariable=var, width=14).grid(row=row, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(scratch, text="读取当前刮卡/Bot 参数", command=lambda: self.run_bg(self.dump_scratch_runtime)).grid(row=2, column=0, columnspan=4, sticky="ew", padx=4, pady=6)
        ttk.Button(scratch, text="应用刮卡/Bot 参数", command=lambda: self.run_scratch_runtime_apply()).grid(row=2, column=4, columnspan=4, sticky="ew", padx=4, pady=6)
        ttk.Label(scratch_box, text="留空表示不改；开启自动重应用后会周期性重写。每秒检测次数夹在 1..240，不循环调用自动下一张。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        bot_box = ttk.LabelFrame(right_form, text="刮刮机器人持久升级：走游戏升级计数", style="Card.TLabelframe")
        bot_box.pack(fill="x", pady=(0, 8))
        bot = ttk.Frame(bot_box)
        bot.pack(fill="x", padx=8, pady=6)
        bot_fields = [
            (self.loc_name("Scratch Bot"), self.bot_unlock_var),
            (self.loc_name("Scratch Bot Speed"), self.bot_speed_var),
            (self.loc_name("Scratch Bot Capacity"), self.bot_capacity_var),
            (self.loc_name("Scratch Bot Strength"), self.bot_strength_var),
        ]
        for index, (label, var) in enumerate(bot_fields):
            col = index * 2
            ttk.Label(bot, text=label).grid(row=0, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(bot, textvariable=var, width=10).grid(row=0, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(bot, text="读取刮刮机器人升级", command=lambda: self.run_bg(self.dump_bot_upgrades)).grid(row=1, column=0, columnspan=4, sticky="ew", padx=4, pady=6)
        ttk.Button(bot, text="应用刮刮机器人升级", command=lambda: self.run_bot_upgrade_apply()).grid(row=1, column=4, columnspan=4, sticky="ew", padx=4, pady=6)
        ttk.Label(bot_box, text="官方名：刮刮机器人。负责自动刮卡；下面的订阅机器人是另一套自动买票系统。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        perk_box = ttk.LabelFrame(right_form, text="单个已有能力：只改现有 Perk entry", style="Card.TLabelframe")
        perk_box.pack(fill="x", pady=(0, 8))
        perk = ttk.Frame(perk_box)
        perk.pack(fill="x", padx=8, pady=6)
        ttk.Label(perk, text="能力名或 PerkType").grid(row=0, column=0, sticky="w", padx=4, pady=3)
        ttk.Entry(perk, textvariable=self.single_perk_target_var, width=24).grid(row=0, column=1, sticky="ew", padx=4, pady=3)
        ttk.Label(perk, text="目标等级").grid(row=0, column=2, sticky="w", padx=4, pady=3)
        ttk.Entry(perk, textvariable=self.single_perk_count_var, width=10).grid(row=0, column=3, sticky="ew", padx=4, pady=3)
        ttk.Button(perk, text="读取这个能力", command=lambda: self.run_bg(self.dump_single_perk)).grid(row=1, column=0, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Button(perk, text="应用这个能力等级", command=lambda: self.run_single_perk_apply()).grid(row=1, column=2, columnspan=2, sticky="ew", padx=4, pady=6)
        perk.columnconfigure(1, weight=1)
        ttk.Label(perk_box, text="只允许编辑已有 activePerks 和已有 boughtPrestigeUpgrades 条目；不会新增能力，不调用 ActivatePerk。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        sub_bot_box = ttk.LabelFrame(right_form, text="订阅机器人：持久升级 + 临时运行时", style="Card.TLabelframe")
        sub_bot_box.pack(fill="x", pady=(0, 8))
        sub_bot = ttk.Frame(sub_bot_box)
        sub_bot.pack(fill="x", padx=8, pady=6)
        sub_bot_fields = [
            (self.loc_name("Subscription Bot"), self.sub_bot_unlock_var),
            (self.loc_name("Buying Speed"), self.buying_speed_var),
        ]
        for index, (label, var) in enumerate(sub_bot_fields):
            col = index * 2
            ttk.Label(sub_bot, text=label).grid(row=0, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(sub_bot, textvariable=var, width=10).grid(row=0, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(sub_bot, text="读取订阅机器人升级", command=lambda: self.run_bg(self.dump_subscription_bot)).grid(row=1, column=0, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Button(sub_bot, text="应用持久升级计数", command=lambda: self.run_subscription_bot_apply()).grid(row=1, column=2, columnspan=2, sticky="ew", padx=4, pady=6)
        sub_runtime_fields = [
            ("处理时长（秒）", self.sub_processing_duration_var),
            ("最大票数", self.sub_max_ticket_count_var),
            ("暂停 0/1", self.sub_paused_var),
            ("购买速度倍率", self.sub_processing_speed_var),
        ]
        for index, (label, var) in enumerate(sub_runtime_fields):
            col = (index % 2) * 2
            row = 2 + index // 2
            ttk.Label(sub_bot, text=label).grid(row=row, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(sub_bot, textvariable=var, width=10).grid(row=row, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(sub_bot, text="读取运行时", command=lambda: self.run_bg(self.dump_subscription_runtime)).grid(row=4, column=0, columnspan=2, sticky="ew", padx=4, pady=3)
        ttk.Button(sub_bot, text="应用临时字段", command=lambda: self.run_subscription_runtime_apply()).grid(row=4, column=2, columnspan=2, sticky="ew", padx=4, pady=3)
        ttk.Label(sub_bot_box, text="官方名：订阅机器人 / 购买速度。运行时处理时长越小买票越快；暂停=0 继续，1 暂停。都只改当前进程，不调用强制买票。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        helper_upgrade_box = ttk.LabelFrame(right_form, text="辅助道具持久升级：写游戏升级计数", style="Card.TLabelframe")
        helper_upgrade_box.pack(fill="x", pady=(0, 8))
        helper_upgrade = ttk.Frame(helper_upgrade_box)
        helper_upgrade.pack(fill="x", padx=8, pady=6)
        helper_upgrade_fields = [
            (self.loc_name("Fan"), self.helper_fan_var), (self.loc_name("Fan Speed"), self.helper_fan_speed_var), (self.loc_name("Fan Battery"), self.helper_fan_battery_var),
            (self.loc_name("Mundo"), self.helper_mundo_var), (self.loc_name("Mundo Speed"), self.helper_mundo_speed_var), (self.loc_name("Spell Book"), self.helper_spell_book_var),
            (self.loc_name("Spell Charge Speed"), self.helper_spell_charge_var), (self.loc_name("Egg Timer"), self.helper_egg_timer_var), (self.loc_name("Timer Capacity"), self.helper_timer_capacity_var),
            (self.loc_name("Timer Charge"), self.helper_timer_charge_var), ("Warp Speed", self.helper_warp_speed_var),
        ]
        for index, (label, var) in enumerate(helper_upgrade_fields):
            row = index // 3
            col = (index % 3) * 2
            ttk.Label(helper_upgrade, text=label).grid(row=row, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(helper_upgrade, textvariable=var, width=10).grid(row=row, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(helper_upgrade, text="读取辅助道具升级", command=lambda: self.run_bg(self.dump_helper_upgrades)).grid(row=4, column=0, columnspan=3, sticky="ew", padx=4, pady=6)
        ttk.Button(helper_upgrade, text="应用辅助升级计数", command=lambda: self.run_helper_upgrade_apply()).grid(row=4, column=3, columnspan=3, sticky="ew", padx=4, pady=6)
        ttk.Label(helper_upgrade_box, text="这是存档升级计数：会改当前存档里的已有升级项。默认值是本地 UpgradeData 上限；留空表示不改。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        progress_box = ttk.LabelFrame(right_form, text="单张刮刮卡进度：只改选中的一张", style="Card.TLabelframe")
        progress_box.pack(fill="x", pady=(0, 8))
        progress = ttk.Frame(progress_box)
        progress.pack(fill="x", padx=8, pady=6)
        ttk.Label(progress, text="刮刮卡").grid(row=0, column=0, sticky="w", padx=4, pady=3)
        ttk.Combobox(progress, textvariable=self.progress_ticket_var, values=list(TICKET_DISPLAY), width=24, state="readonly").grid(row=0, column=1, sticky="ew", padx=4, pady=3)
        ttk.Label(progress, text="等级").grid(row=0, column=2, sticky="w", padx=4, pady=3)
        ttk.Entry(progress, textvariable=self.progress_level_var, width=10).grid(row=0, column=3, sticky="ew", padx=4, pady=3)
        ttk.Label(progress, text="经验").grid(row=0, column=4, sticky="w", padx=4, pady=3)
        ttk.Entry(progress, textvariable=self.progress_xp_var, width=12).grid(row=0, column=5, sticky="ew", padx=4, pady=3)
        ttk.Button(progress, text="读取这张票进度", command=lambda: self.run_bg(self.dump_ticket_progress)).grid(row=1, column=0, columnspan=3, sticky="ew", padx=4, pady=6)
        ttk.Button(progress, text="应用这张票等级/经验", command=lambda: self.run_ticket_progress_apply()).grid(row=1, column=3, columnspan=3, sticky="ew", padx=4, pady=6)
        ttk.Label(progress_box, text="比“解锁全部票”粒度更细：只写选中的 ticketProgressionData.level/xp，不补 jackpot 列表。留空表示不改。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        loan_box = ttk.LabelFrame(right_form, text="贷款清理：LoanGroup.Save / loanCount", style="Card.TLabelframe")
        loan_box.pack(fill="x", pady=(0, 8))
        loan = ttk.Frame(loan_box)
        loan.pack(fill="x", padx=8, pady=6)
        loan_fields = [
            ("贷款计数", self.loan_count_var), ("贷款列表长度", self.loan_list_size_var), ("第一条 index", self.loan_index_var),
            ("第一条 loanNum", self.loan_num_var), ("第一条 severity", self.loan_severity_var), ("第一条 amount", self.loan_amount_var),
        ]
        for index, (label, var) in enumerate(loan_fields):
            row = index // 3
            col = (index % 3) * 2
            ttk.Label(loan, text=label).grid(row=row, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(loan, textvariable=var, width=12).grid(row=row, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(loan, text="读取贷款状态", command=lambda: self.run_bg(self.dump_loan_state)).grid(row=2, column=0, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Button(loan, text="应用贷款字段", command=lambda: self.run_loan_apply()).grid(row=2, column=2, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Button(loan, text="清空贷款", style="Danger.TButton", command=lambda: self.run_loan_clear()).grid(row=2, column=4, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Label(loan_box, text="清空贷款会把 SaveData.loanCount 和 LayerOne.loans 的 List size 置 0；不新增托管对象，不调用 LoanPanel 原生函数。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        helper_state_box = ttk.LabelFrame(right_form, text="辅助状态救援：充能 / 暂停 / 死亡标记", style="Card.TLabelframe")
        helper_state_box.pack(fill="x", pady=(0, 8))
        helper_state = ttk.Frame(helper_state_box)
        helper_state.pack(fill="x", padx=8, pady=6)
        helper_state_fields = [
            ("电扇剩余电量", self.electric_fan_charge_var), ("风扇暂停 0/1", self.fan_paused_var), ("计时器剩余充能", self.egg_timer_charge_left_var),
            ("蒙多死亡 0/1", self.mundo_dead_var), ("垃圾桶死亡 0/1", self.trash_can_dead_var),
        ]
        for index, (label, var) in enumerate(helper_state_fields):
            row = index // 3
            col = (index % 3) * 2
            ttk.Label(helper_state, text=label).grid(row=row, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(helper_state, textvariable=var, width=12).grid(row=row, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(helper_state, text="读取辅助状态", command=lambda: self.run_bg(self.dump_helper_state)).grid(row=2, column=0, columnspan=3, sticky="ew", padx=4, pady=6)
        ttk.Button(helper_state, text="应用救援状态", command=lambda: self.run_helper_state_apply()).grid(row=2, column=3, columnspan=3, sticky="ew", padx=4, pady=6)
        ttk.Label(helper_state_box, text="写 LayerOne 标量：电扇/计时器充能、风扇暂停、蒙多/垃圾桶死亡标记。默认 0=解除暂停/复活，留空表示不改。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        gadget_box = ttk.LabelFrame(right_form, text="辅助道具运行时倍率：重启游戏会恢复", style="Card.TLabelframe")
        gadget_box.pack(fill="x", pady=(0, 8))
        gadget = ttk.Frame(gadget_box)
        gadget.pack(fill="x", padx=8, pady=6)
        gadget_fields = [
            ("计时器容量倍率", self.eggtimer_capacity_var), ("计时器充能倍率", self.eggtimer_charge_var), ("计时器收益倍率", self.eggtimer_mult_var),
            ("风扇容量倍率", self.fan_capacity_var), ("风扇充能倍率", self.fan_charge_var), ("风扇吹动速度倍率", self.fan_speed_var),
            ("蒙多领奖速度倍率", self.mundo_claim_speed_var), ("刮刮机器人速度倍率", self.scratchbot_speed_mult_var), ("刮刮机器人额外速度", self.scratchbot_extra_speed_var),
            ("刮刮机器人额外容量", self.scratchbot_extra_capacity_var), ("刮刮机器人额外强度", self.scratchbot_extra_strength_var), ("法术书充能倍率", self.spellbook_recharge_var),
        ]
        for index, (label, var) in enumerate(gadget_fields):
            row = index // 3
            col = (index % 3) * 2
            ttk.Label(gadget, text=label).grid(row=row, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(gadget, textvariable=var, width=12).grid(row=row, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(gadget, text="读取辅助道具倍率", command=lambda: self.run_bg(self.dump_gadget_runtime)).grid(row=4, column=0, columnspan=3, sticky="ew", padx=4, pady=6)
        ttk.Button(gadget, text="应用临时道具倍率", command=lambda: self.run_gadget_runtime_apply()).grid(row=4, column=3, columnspan=3, sticky="ew", padx=4, pady=6)
        ttk.Label(gadget_box, text="影响煮蛋计时器、风扇、蒙多、刮刮机器人、法术书这类辅助道具；不是升级计数，不写存档。留空表示不改，建议先读当前值。", style="Hint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        experimental_box = ttk.LabelFrame(right_form, text="实验运行时：流程控制字段（重启恢复）", style="Card.TLabelframe")
        experimental_box.pack(fill="x", pady=(0, 8))
        experimental = ttk.Frame(experimental_box)
        experimental.pack(fill="x", padx=8, pady=6)
        experimental_fields = [
            ("刮刮机器人处理时长（秒）", self.scratchbot_processing_duration_var),
            ("蒙多暂停 0/1", self.mundo_paused_runtime_var),
        ]
        for index, (label, var) in enumerate(experimental_fields):
            col = index * 2
            ttk.Label(experimental, text=label).grid(row=0, column=col, sticky="w", padx=4, pady=3)
            ttk.Entry(experimental, textvariable=var, width=14).grid(row=0, column=col + 1, sticky="ew", padx=4, pady=3)
        ttk.Button(experimental, text="读取实验运行时", command=lambda: self.run_bg(self.dump_experimental_runtime)).grid(row=1, column=0, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Button(experimental, text="应用实验运行时", command=lambda: self.run_experimental_runtime_apply()).grid(row=1, column=2, columnspan=2, sticky="ew", padx=4, pady=6)
        ttk.Label(experimental_box, text="实验区只改当前进程字段：processingDuration 越小刮刮机器人处理越快；Mundo.paused=0 解除暂停。留空不改，不调用原生方法。", style="DangerHint.TLabel").pack(anchor="w", padx=12, pady=(0, 8))

        chance_box = ttk.LabelFrame(right_form, text="运行时符号几率：每张刮刮卡 / 每个符号", style="Card.TLabelframe")
        chance_box.pack(fill="x", pady=(0, 8))
        form = ttk.Frame(chance_box)
        form.pack(fill="x", padx=8, pady=6)
        ttk.Label(form, text="刮刮卡类型").grid(row=0, column=0, sticky="w", padx=4, pady=3)
        ticket_combo = ttk.Combobox(form, textvariable=self.ticket_var, values=list(TICKET_DISPLAY), width=24, state="readonly")
        ticket_combo.grid(row=0, column=1, sticky="ew", padx=4, pady=3)
        ticket_combo.bind("<<ComboboxSelected>>", lambda _event: self.update_symbol_choices())
        ttk.Label(form, text="符号名字").grid(row=0, column=2, sticky="w", padx=4, pady=3)
        self.symbol_combo = ttk.Combobox(form, textvariable=self.symbol_name_var, values=[], width=28)
        self.symbol_combo.grid(row=0, column=3, sticky="ew", padx=4, pady=3)
        ttk.Label(form, text="SJP 权重").grid(row=0, column=4, sticky="w", padx=4, pady=3)
        ttk.Entry(form, textvariable=self.sjp_chance_var, width=12).grid(row=0, column=5, sticky="w", padx=4, pady=3)
        ttk.Button(form, text="应用 SJP 权重", style="Danger.TButton", command=lambda: self.run_sjp_chance_apply()).grid(row=0, column=6, sticky="ew", padx=4, pady=3)
        ttk.Label(form, text="符号类别").grid(row=1, column=0, sticky="w", padx=4, pady=3)
        ttk.Combobox(form, textvariable=self.symbol_type_var, values=list(SYMBOL_TYPES), width=24, state="readonly").grid(row=1, column=1, sticky="ew", padx=4, pady=3)
        ttk.Label(form, text="目标权重").grid(row=1, column=2, sticky="w", padx=4, pady=3)
        ttk.Entry(form, textvariable=self.weight_var, width=16).grid(row=1, column=3, sticky="w", padx=4, pady=3)
        ttk.Label(form, text="幸运等级索引（-1=全改）").grid(row=2, column=0, sticky="w", padx=4, pady=3)
        ttk.Entry(form, textvariable=self.luck_index_var, width=10).grid(row=2, column=1, sticky="w", padx=4, pady=3)
        ttk.Button(form, text="读取这张刮刮卡当前几率", command=lambda: self.run_bg(self.dump_symbol_chances)).grid(row=2, column=2, sticky="ew", padx=4, pady=3)
        ttk.Button(form, text="强制实时读取", command=lambda: self.run_bg(lambda: self.dump_symbol_chances(force_live=True))).grid(row=2, column=3, sticky="ew", padx=4, pady=3)
        ttk.Button(form, text="预览符号改动", command=lambda: self.run_symbol_apply(dryrun=True)).grid(row=2, column=4, sticky="ew", padx=4, pady=3)
        ttk.Button(form, text="应用到这张刮刮卡", command=lambda: self.run_symbol_apply(dryrun=False)).grid(row=2, column=5, columnspan=2, sticky="ew", padx=4, pady=3)
        form.columnconfigure(3, weight=1)
        form.columnconfigure(6, weight=1)
        ttk.Label(chance_box, text="读取优先使用本地票/符号缓存，几乎秒开；符号下拉会随刮刮卡类型自动切换。清空符号名后可按类别批量改。", foreground="#555").pack(anchor="w", padx=12, pady=(0, 8))
        self.update_symbol_choices()

        log_box = ttk.LabelFrame(right, text="运行日志", style="Card.TLabelframe")
        log_box.pack(fill="x", expand=False)
        self.log_box = scrolledtext.ScrolledText(log_box, wrap="word", height=12, font=("Consolas", 10), bg="#ffffff", fg="#111827", insertbackground="#111827", relief="flat")
        self.log_box.pack(fill="x", expand=False, padx=6, pady=6)

    def make_scrollable(self, parent):
        shell = ttk.Frame(parent, style="Panel.TFrame")
        canvas = tk.Canvas(shell, bg="#f6f7fb", highlightthickness=0, borderwidth=0)
        scrollbar = ttk.Scrollbar(shell, orient="vertical", command=canvas.yview)
        content = ttk.Frame(canvas, style="Panel.TFrame")
        window_id = canvas.create_window((0, 0), window=content, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)
        canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")

        def update_scroll_region(_event=None):
            canvas.configure(scrollregion=canvas.bbox("all"))

        def update_content_width(event):
            canvas.itemconfigure(window_id, width=event.width)

        content.bind("<Configure>", update_scroll_region)
        canvas.bind("<Configure>", update_content_width)
        self.scroll_regions.append((shell, canvas))
        return shell, content

    @staticmethod
    def widget_is_child_of(widget, ancestor) -> bool:
        while widget:
            if widget == ancestor:
                return True
            parent_name = widget.winfo_parent()
            if not parent_name:
                return False
            try:
                widget = widget.nametowidget(parent_name)
            except tk.TclError:
                return False
        return False

    def route_mousewheel(self, event):
        if getattr(event, "num", None) == 4:
            delta = -1
        elif getattr(event, "num", None) == 5:
            delta = 1
        else:
            delta = int(-1 * (event.delta / 120)) if event.delta else 0
        if delta == 0:
            return "break"
        widget = self.winfo_containing(event.x_root, event.y_root)
        if widget and hasattr(self, "log_box") and self.widget_is_child_of(widget, self.log_box):
            self.log_box.yview_scroll(delta, "units")
            return "break"
        x, y = event.x_root, event.y_root
        for shell, canvas in reversed(self.scroll_regions):
            left = shell.winfo_rootx()
            top = shell.winfo_rooty()
            right = left + shell.winfo_width()
            bottom = top + shell.winfo_height()
            if left <= x <= right and top <= y <= bottom:
                canvas.yview_scroll(delta, "units")
                return "break"
        return None

    def _setup_styles(self):
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Hero.TFrame", background="#ffffff", relief="flat")
        style.configure("Panel.TFrame", background="#f6f7fb")
        style.configure("HeroTitle.TLabel", background="#ffffff", foreground="#111827", font=("Microsoft YaHei UI", 17, "bold"))
        style.configure("HeroStatus.TLabel", background="#ffffff", foreground="#2563eb", font=("Microsoft YaHei UI", 10, "bold"))
        style.configure("Hint.TLabel", background="#f6f7fb", foreground="#64748b", font=("Microsoft YaHei UI", 9))
        style.configure("SectionHint.TLabel", background="#f6f7fb", foreground="#334155", font=("Microsoft YaHei UI", 10))
        style.configure("Card.TLabelframe", background="#ffffff", foreground="#111827", bordercolor="#e2e8f0", relief="solid")
        style.configure("Card.TLabelframe.Label", background="#ffffff", foreground="#111827", font=("Microsoft YaHei UI", 10, "bold"))
        style.configure("Action.TButton", font=("Microsoft YaHei UI", 10), padding=(8, 5))
        style.configure("Accent.TButton", font=("Microsoft YaHei UI", 10, "bold"), padding=(10, 6), foreground="#1d4ed8")
        style.configure("Danger.TButton", font=("Microsoft YaHei UI", 10), padding=(8, 5), foreground="#b91c1c")
        style.configure("DangerHint.TLabel", background="#ffffff", foreground="#b91c1c", font=("Microsoft YaHei UI", 9))
        style.configure("TFrame", background="#f6f7fb")
        style.configure("TLabel", background="#f6f7fb", foreground="#111827")
        style.configure("TCheckbutton", background="#f6f7fb", foreground="#334155")
        style.configure("TNotebook", background="#f6f7fb", borderwidth=0)
        style.configure("TNotebook.Tab", padding=(14, 7), font=("Microsoft YaHei UI", 10))

    def log(self, text: str):
        if threading.current_thread() is not threading.main_thread():
            self.after(0, lambda: self.log(text))
            return
        stamp = time.strftime("%H:%M:%S")
        self.log_box.insert("end", f"[{stamp}] {text}\n")
        self.log_box.see("end")

    def set_status(self, text: str):
        if threading.current_thread() is not threading.main_thread():
            self.after(0, lambda: self.status.set(text))
        else:
            self.status.set(text)

    @staticmethod
    def load_symbol_cache() -> dict:
        if not SYMBOL_DATA_JSON.exists():
            return {}
        try:
            return json.loads(SYMBOL_DATA_JSON.read_text(encoding="utf-8-sig"))
        except Exception:
            return {}

    @staticmethod
    def load_localization() -> dict:
        if not LOCALIZATION_JSON.exists():
            return {}
        try:
            return json.loads(LOCALIZATION_JSON.read_text(encoding="utf-8-sig"))
        except Exception:
            return {}

    def loc_name(self, item_id: str) -> str:
        zh = self.localization.get(f"{item_id}_name")
        return f"{zh}（{item_id}）" if zh else item_id

    @staticmethod
    def index_symbols_by_ticket(symbol_data: dict) -> dict[str, list[dict]]:
        grouped: dict[str, list[dict]] = {}
        for symbol in symbol_data.values():
            if isinstance(symbol, dict):
                grouped.setdefault(str(symbol.get("ticketID", "")), []).append(symbol)
        for items in grouped.values():
            items.sort(key=lambda item: (int(item.get("type", 0)), str(item.get("id", ""))))
        return grouped

    def update_symbol_choices(self):
        ticket_id = self.current_ticket_id()
        choices = [self.display_symbol(str(item.get("id", ""))) for item in self.symbols_by_ticket.get(ticket_id, [])]
        if self.symbol_combo is not None:
            self.symbol_combo.configure(values=choices)
        current = self.extract_symbol_id(self.symbol_name_var.get().strip())
        valid_ids = {str(item.get("id", "")) for item in self.symbols_by_ticket.get(ticket_id, [])}
        if current and current in valid_ids:
            return
        self.symbol_name_var.set(choices[0] if choices else "")

    @staticmethod
    def symbol_type_label(type_value) -> str:
        labels = {
            -1: "坏符号（推断）/ Bad",
            0: "空符号（推断）/ Dud",
            1: "小奖（推断）/ Small",
            2: "头奖 / Jackpot",
            3: "超级头奖 / Super Jackpot",
            4: "倍率（推断）/ Multiplier",
            5: "自毁（推断）/ Self Destruct",
        }
        try:
            key = int(float(type_value))
        except (TypeError, ValueError):
            return f"未知 / {type_value}"
        return labels.get(key, f"未知 / {key}")

    @staticmethod
    def fmt_weight(value) -> str:
        try:
            number = float(value)
        except (TypeError, ValueError):
            return str(value)
        if number.is_integer():
            return str(int(number))
        return f"{number:g}"

    def format_cached_symbol_table(self, ticket_id: str) -> str:
        items = self.symbols_by_ticket.get(ticket_id, [])
        if not items:
            return ""
        ticket_name = next((name for name, internal in TICKET_DISPLAY.items() if internal == ticket_id), ticket_id)
        rows = []
        for item in items:
            symbol_id = str(item.get("id", ""))
            chances = item.get("chances", [])
            if not isinstance(chances, list):
                chances = []
            weights = [self.fmt_weight(chances[index]) if index < len(chances) else "" for index in range(7)]
            rows.append([
                self.display_symbol(symbol_id),
                self.symbol_type_label(item.get("type")),
                *weights,
            ])

        lines = [
            f"{ticket_name} / {ticket_id} 符号权重（本地缓存，秒读）",
            "说明：L0-L6 是不同幸运等级下的权重；数字越大越容易出现，不是百分比。",
            "",
        ]
        for row in rows:
            symbol, type_name, *weights = row
            lines.extend([
                f"【{symbol}】",
                f"  类别：{type_name}",
                "  权重：" + " ｜ ".join(f"L{index}={weights[index]}" for index in range(7)),
                "",
            ])
        return "\n".join(lines).rstrip()

    def run_bg(self, fn):
        if self.busy:
            return
        threading.Thread(target=lambda: self._guard(fn), daemon=True).start()

    def _guard(self, fn):
        self.busy = True
        try:
            fn()
        except TimeoutError as exc:
            self.log(f"CE 管道忙，稍后会自动重试：{exc}")
            self.status.set("CE 管道忙；稍后重试")
        except Exception as exc:
            self.log(f"出错：{exc}")
            self.status.set(f"出错：{exc}")
        finally:
            self.busy = False

    def start_ce(self):
        ce_path = find_ce_path()
        if ce_path:
            subprocess.Popen([str(ce_path)], close_fds=True)
            self.log(f"已启动 CE：{ce_path}")
        else:
            messagebox.showerror("CE 不存在", "未找到 Cheat Engine。可设置环境变量 CHEAT_ENGINE_EXE 指向 cheatengine-x86_64.exe。")

    def start_game(self):
        launched = False
        steam_exe = find_steam_exe()
        if steam_exe:
            subprocess.Popen([str(steam_exe), "-applaunch", GAME_STEAM_APP_ID], close_fds=True)
            self.log(f"已通过 Steam 启动游戏：AppID {GAME_STEAM_APP_ID}")
            launched = True
        else:
            try:
                os.startfile(f"steam://rungameid/{GAME_STEAM_APP_ID}")
                self.log(f"已通过 Steam 协议启动游戏：AppID {GAME_STEAM_APP_ID}")
                launched = True
            except OSError:
                pass
        if not launched:
            game_path = find_game_path()
            if game_path:
                subprocess.Popen([str(game_path)], cwd=str(game_path.parent), close_fds=True)
                self.log(f"未找到 Steam，只能直接启动游戏：{game_path}")
                launched = True
        if not launched:
            messagebox.showerror("游戏不存在", "未找到 Steam 或 Scritchy Scratchy。可设置环境变量 STEAM_EXE 指向 steam.exe，或 SCRITCHY_GAME_EXE 指向 ScritchyScratchy.exe。")
            return
        if self.auto_attach_enabled.get():
            self.run_bg(lambda: self.wait_and_attach_game(90))

    def run_verify_api(self):
        if not VERIFY_API.exists():
            self.log("验证 API 不存在：" + str(VERIFY_API))
            return
        self.client.close()
        self.log("开始安全验证；默认使用写入后恢复，不污染现场值。")
        proc = subprocess.run(
            [sys.executable, str(VERIFY_API), "--shared-client", "--wait-ready", "120", "--report", str(VERIFY_REPORT)],
            cwd=str(ROOT_DIR),
            text=True,
            capture_output=True,
            timeout=900,
        )
        output = (proc.stdout + "\n" + proc.stderr).strip()
        self.log(output or f"验证结束，退出码={proc.returncode}")
        if VERIFY_REPORT.exists():
            self.log("验证报告：" + str(VERIFY_REPORT))
            self.log(self.summarize_verify_report())

    def open_verify_report(self):
        if VERIFY_REPORT.exists():
            subprocess.Popen(["notepad.exe", str(VERIFY_REPORT)], close_fds=True)
        else:
            messagebox.showinfo("验证报告", "还没有验证报告，先点“运行安全验证”。")

    def summarize_verify_report(self) -> str:
        try:
            data = json.loads(VERIFY_REPORT.read_text(encoding="utf-8-sig"))
        except Exception as exc:
            return f"验证报告读取失败：{exc}"
        results = data.get("results", [])
        passed = [item for item in results if item.get("ok")]
        failed = [item for item in results if not item.get("ok")]
        mode = "安全验证：含写入后恢复" if not data.get("destructive_cases_included") else "包含持久/污染项验证"
        lines = [
            f"验证摘要：{mode}，通过 {len(passed)}，失败 {len(failed)}。",
            "通过项：" + ("、".join(str(item.get("name")) for item in passed[:12]) if passed else "无"),
        ]
        if len(passed) > 12:
            lines[-1] += f" 等 {len(passed)} 项"
        if failed:
            lines.append("失败项：")
            for item in failed[:8]:
                lines.append(f"- {item.get('name')}: {item.get('summary') or item.get('error')}")
        return "\n".join(lines)

    def bootstrap(self):
        if not self.pipe_available(500):
            self.start_ce()
            time.sleep(2.0)
        self.ensure_connected()
        if not self.find_game_pid():
            self.log("CE 已准备好；没看到游戏，开始通过 Steam 启动并等待连接")
            self.start_game()
            self.wait_and_attach_game(90)
            return
        self.attach_game()

    def wait_and_attach_game(self, timeout_sec=90):
        deadline = time.time() + timeout_sec
        self.status.set("等待游戏进程")
        while time.time() < deadline:
            try:
                pid = self.find_game_pid()
                if pid:
                    self.log(f"检测到游戏进程：{pid}，正在连接")
                    self.attach_game()
                    return True
            except Exception as exc:
                self.log(f"等待游戏时暂时失败：{exc}")
            time.sleep(1.0)
        self.status.set("等待游戏超时")
        self.log(f"等待游戏超时：{timeout_sec}s")
        return False

    def pipe_available(self, timeout_ms=500) -> bool:
        try:
            win32pipe.WaitNamedPipe(PIPE_NAME, timeout_ms)
            return True
        except Exception:
            return False

    def ensure_connected(self):
        last_error = None
        for timeout in (1200, 3000, 8000, 15000):
            try:
                self.client.connect(timeout)
                return
            except Exception as exc:
                last_error = exc
                self.client.close()
                time.sleep(0.25)
        raise TimeoutError(f"CE 管道连接失败：{last_error}")

    def find_game_pid(self) -> int | None:
        self.ensure_connected()
        res = self.client.lua("local pid=getProcessIDFromProcessName('ScritchyScratchy.exe'); return tostring(pid or '')")
        text = str(res.get("result", "") if isinstance(res, dict) else res)
        try:
            pid = int(text)
            return pid if pid > 0 else None
        except ValueError:
            return None

    def attach_game(self):
        self.ensure_connected()
        res = self.client.lua(f"openProcess('{GAME_EXE}'); return tostring(getOpenedProcessID())")
        text = str(res.get("result", "") if isinstance(res, dict) else res)
        try:
            self.last_attached_pid = int(text)
        except ValueError:
            pass
        self.log("已连接游戏：" + text)
        self.refresh_status_once()

    def suite_code(self, action_key: str, extra: str = "") -> str:
        lua_path = str(SAFE_SUITE).replace("\\", "\\\\")
        return f"{extra}\nSCRITCHY_SAFE_ACTION='{action_key}'\nlocal ok,res=pcall(dofile,'{lua_path}')\nreturn tostring(ok)..' :: '..tostring(res)"

    def run_action(self, action: Action):
        if action.caution and not messagebox.askyesno("确认写入", f"{action.label}\n\n{action.description}"):
            return
        self.run_bg(lambda: self._run_action(action))

    def _run_action(self, action: Action):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log(f"执行：{action.label}")
        res = self.client.lua(self.suite_code(action.key))
        self.log(self.clean_result(res, action.key))
        self.sync_keep_flags_after_action(action.key, res)
        self.refresh_status_once()

    @staticmethod
    def lua_number_or_nil(text: str) -> str:
        value = text.strip()
        if not value:
            return "nil"
        float(value)
        return value

    def run_custom_save_fields(self, only: str | None = None):
        target = {"money": "金钱", "tokens": "代币"}.get(only, "全部填写项")
        if not messagebox.askyesno("确认写入", f"这会在游戏运行时直接修改：{target}。\n留空的项目不会改。"):
            return
        self.run_bg(lambda: self.apply_custom_save_fields(only))

    def build_custom_save_extra(self, only: str | None = None) -> str:
        values = {
            "money": self.money_var.get(),
            "tokens": self.tokens_var.get(),
            "souls": self.souls_var.get(),
            "prestige_currency": self.prestige_currency_var.get(),
            "prestige_count": self.prestige_count_var.get(),
            "act": self.act_var.get(),
        }
        if only:
            values = {key: (value if key == only else "") for key, value in values.items()}
        return "\n".join([
            f"SCRITCHY_CUSTOM_MONEY={self.lua_number_or_nil(values['money'])}",
            f"SCRITCHY_CUSTOM_TOKENS={self.lua_number_or_nil(values['tokens'])}",
            f"SCRITCHY_CUSTOM_SOULS={self.lua_number_or_nil(values['souls'])}",
            f"SCRITCHY_CUSTOM_PRESTIGE_CURRENCY={self.lua_number_or_nil(values['prestige_currency'])}",
            f"SCRITCHY_CUSTOM_PRESTIGE_COUNT={self.lua_number_or_nil(values['prestige_count'])}",
            f"SCRITCHY_CUSTOM_ACT={self.lua_number_or_nil(values['act'])}",
        ])

    def apply_custom_save_fields(self, only: str | None = None):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        extra = self.build_custom_save_extra(only)
        self.log("运行时修改存档数值" + (f"：{only}" if only else ""))
        res = self.client.lua(self.suite_code("custom_save_fields", extra))
        self.log(self.clean_result(res, "custom_save_fields"))
        self.refresh_status_once()

    def run_custom_unlock(self):
        if not messagebox.askyesno("确认写入", "这会按你填写的等级/经验修改全部刮刮卡进度。"):
            return
        self.run_bg(self.apply_custom_unlock)

    def apply_custom_unlock(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        level = int(float(self.unlock_level_var.get().strip()))
        xp = int(float(self.unlock_xp_var.get().strip()))
        extra = f"SCRITCHY_UNLOCK_LEVEL={level}\nSCRITCHY_UNLOCK_XP={xp}"
        self.log(f"按自定义等级/经验解锁全部票：level={level} xp={xp}")
        res = self.client.lua(self.suite_code("online_unlock", extra))
        self.log(self.clean_result(res, "online_unlock"))
        self.refresh_status_once()

    def build_scratch_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_SCRATCH_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_SCRATCH_PARTICLE_SPEED={self.lua_number_or_nil(self.scratch_particle_speed_var.get())}",
            f"SCRITCHY_MOUSE_VELOCITY_MAX={self.lua_number_or_nil(self.mouse_velocity_max_var.get())}",
            f"SCRITCHY_SCRATCH_CHECKS_PER_SECOND={self.lua_number_or_nil(self.scratch_checks_var.get())}",
            f"SCRITCHY_SCRATCH_LUCK={self.lua_number_or_nil(self.scratch_luck_var.get())}",
            f"SCRITCHY_LUCK_REDUCTION={self.lua_number_or_nil(self.luck_reduction_var.get())}",
            f"SCRITCHY_TOOL_STRENGTH={self.lua_number_or_nil(self.tool_strength_var.get())}",
            f"SCRITCHY_TOOL_SIZE={self.lua_number_or_nil(self.tool_size_var.get())}",
            f"SCRITCHY_TOOL_SIZE_REDUCTION={self.lua_number_or_nil(self.tool_size_reduction_var.get())}",
        ])

    def dump_runtime_status(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取运行时总状态")
        res = self.client.lua(self.suite_code("runtime_status"))
        self.log(self.clean_result(res, "runtime_status"))
        self.refresh_status_once()

    def dump_scratch_runtime(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取刮卡/Bot 运行时参数")
        res = self.client.lua(self.suite_code("scratch_status", self.build_scratch_extra("status")))
        self.log(self.clean_result(res, "scratch_status"))
        self.refresh_status_once()

    def run_scratch_runtime_apply(self):
        if not messagebox.askyesno("确认写入", "这会直接修改当前游戏进程里的刮卡/Bot 参数，重启游戏通常会恢复。"):
            return
        self.run_bg(self.apply_scratch_runtime)

    def apply_scratch_runtime(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("应用刮卡/Bot 运行时参数")
        res = self.client.lua(self.suite_code("scratch_apply", self.build_scratch_extra("apply")))
        self.log(self.clean_result(res, "scratch_apply"))
        self.refresh_status_once()

    def build_bot_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_BOT_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_BOT_UNLOCK={self.lua_number_or_nil(self.bot_unlock_var.get())}",
            f"SCRITCHY_BOT_SPEED={self.lua_number_or_nil(self.bot_speed_var.get())}",
            f"SCRITCHY_BOT_CAPACITY={self.lua_number_or_nil(self.bot_capacity_var.get())}",
            f"SCRITCHY_BOT_STRENGTH={self.lua_number_or_nil(self.bot_strength_var.get())}",
        ])

    def dump_bot_upgrades(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取刮刮机器人升级计数")
        res = self.client.lua(self.suite_code("bot_upgrade_status", self.build_bot_extra("status")))
        self.log(self.clean_result(res, "bot_upgrade_status"))
        self.refresh_status_once()

    def run_bot_upgrade_apply(self):
        if not messagebox.askyesno("确认写入", "这会修改当前存档里的刮刮机器人升级计数，通常会被游戏自动保存。"):
            return
        self.run_bg(self.apply_bot_upgrades)

    def apply_bot_upgrades(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("应用刮刮机器人升级计数")
        res = self.client.lua(self.suite_code("bot_upgrade_apply", self.build_bot_extra("apply")))
        self.log(self.clean_result(res, "bot_upgrade_apply"))
        self.refresh_status_once()

    def dump_single_perk(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log(f"读取单个能力：{self.single_perk_target_var.get().strip()}")
        res = self.client.lua(self.suite_code("single_perk_status", self.build_single_perk_extra("status")))
        self.log(self.clean_result(res, "single_perk_status"))
        self.refresh_status_once()

    def run_single_perk_apply(self):
        if not messagebox.askyesno("确认写入", "这会同步修改一个已有能力的运行时等级和存档等级。\n不会新增能力，不调用 ActivatePerk。"):
            return
        self.run_bg(self.apply_single_perk)

    def apply_single_perk(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log(f"应用单个能力：{self.single_perk_target_var.get().strip()}")
        res = self.client.lua(self.suite_code("single_perk_apply", self.build_single_perk_extra("apply")))
        self.log(self.clean_result(res, "single_perk_apply"))
        self.refresh_status_once()

    def dump_subscription_bot(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取订阅机器人升级计数")
        res = self.client.lua(self.suite_code("subscription_bot_status", self.build_subscription_bot_extra("status")))
        self.log(self.clean_result(res, "subscription_bot_status"))
        self.refresh_status_once()

    def run_subscription_bot_apply(self):
        if not messagebox.askyesno("确认写入", "这会修改当前存档里的订阅机器人/购买速度升级计数，通常会被游戏自动保存。"):
            return
        self.run_bg(self.apply_subscription_bot)

    def apply_subscription_bot(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("应用订阅机器人升级计数")
        res = self.client.lua(self.suite_code("subscription_bot_apply", self.build_subscription_bot_extra("apply")))
        self.log(self.clean_result(res, "subscription_bot_apply"))
        self.refresh_status_once()

    def dump_subscription_runtime(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取订阅机器人运行时")
        res = self.client.lua(self.suite_code("subscription_runtime_status", self.build_subscription_runtime_extra("status")))
        self.log(self.clean_result(res, "subscription_runtime_status"))
        self.refresh_status_once()

    def run_subscription_runtime_apply(self):
        if not messagebox.askyesno("确认写入", "这会修改当前进程里的订阅机器人运行时购买速度倍率，重启游戏通常会恢复。"):
            return
        self.run_bg(self.apply_subscription_runtime)

    def apply_subscription_runtime(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("应用订阅机器人运行时倍率")
        res = self.client.lua(self.suite_code("subscription_runtime_apply", self.build_subscription_runtime_extra("apply")))
        self.log(self.clean_result(res, "subscription_runtime_apply"))
        self.refresh_status_once()

    def dump_helper_upgrades(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取辅助道具升级计数")
        res = self.client.lua(self.suite_code("helper_upgrade_status", self.build_helper_upgrade_extra("status")))
        self.log(self.clean_result(res, "helper_upgrade_status"))
        self.refresh_status_once()

    def run_helper_upgrade_apply(self):
        if not messagebox.askyesno("确认写入", "这会修改当前存档里的辅助道具升级计数，通常会被游戏自动保存。\n留空的项目不会改。"):
            return
        self.run_bg(self.apply_helper_upgrades)

    def apply_helper_upgrades(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("应用辅助道具升级计数")
        res = self.client.lua(self.suite_code("helper_upgrade_apply", self.build_helper_upgrade_extra("apply")))
        self.log(self.clean_result(res, "helper_upgrade_apply"))
        self.refresh_status_once()

    def current_progress_ticket_id(self) -> str:
        selected = self.progress_ticket_var.get().strip()
        return TICKET_DISPLAY.get(selected, selected)

    def dump_ticket_progress(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        ticket_id = self.current_progress_ticket_id()
        self.log(f"读取单票进度：{self.progress_ticket_var.get()} / {ticket_id}")
        res = self.client.lua(self.suite_code("ticket_progress_status", self.build_ticket_progress_extra("status")))
        self.log(self.clean_result(res, "ticket_progress_status"))
        self.refresh_status_once()

    def run_ticket_progress_apply(self):
        if not messagebox.askyesno("确认写入", "这只修改当前存档里选中刮刮卡的等级/经验。\n留空的项目不会改。"):
            return
        self.run_bg(self.apply_ticket_progress)

    def apply_ticket_progress(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        ticket_id = self.current_progress_ticket_id()
        self.log(f"应用单票进度：{self.progress_ticket_var.get()} / {ticket_id}")
        res = self.client.lua(self.suite_code("ticket_progress_apply", self.build_ticket_progress_extra("apply")))
        self.log(self.clean_result(res, "ticket_progress_apply"))
        self.refresh_status_once()

    def dump_loan_state(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取贷款状态")
        res = self.client.lua(self.suite_code("loan_status", self.build_loan_extra("status")))
        self.log(self.clean_result(res, "loan_status"))
        self.refresh_status_once()

    def run_loan_apply(self):
        if not messagebox.askyesno("确认写入", "这会修改当前存档里的贷款计数、贷款列表长度或第一条贷款字段。\n留空的项目不会改。"):
            return
        self.run_bg(self.apply_loan_state)

    def apply_loan_state(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("应用贷款字段")
        res = self.client.lua(self.suite_code("loan_apply", self.build_loan_extra("apply")))
        self.log(self.clean_result(res, "loan_apply"))
        self.refresh_status_once()

    def run_loan_clear(self):
        if not messagebox.askyesno("确认清空贷款", "这会把当前存档贷款计数和贷款列表长度置 0，通常会被游戏保存。"):
            return
        self.run_bg(self.clear_loan_state)

    def clear_loan_state(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("清空贷款")
        res = self.client.lua(self.suite_code("loan_clear"))
        self.log(self.clean_result(res, "loan_clear"))
        self.refresh_status_once()

    def dump_helper_state(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取辅助状态")
        res = self.client.lua(self.suite_code("helper_state_status", self.build_helper_state_extra("status")))
        self.log(self.clean_result(res, "helper_state_status"))
        self.refresh_status_once()

    def run_helper_state_apply(self):
        if not messagebox.askyesno("确认写入", "这会修改当前存档里的辅助状态标量：电量、暂停、死亡标记。\n留空的项目不会改。"):
            return
        self.run_bg(self.apply_helper_state)

    def apply_helper_state(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("应用辅助状态救援")
        res = self.client.lua(self.suite_code("helper_state_apply", self.build_helper_state_extra("apply")))
        self.log(self.clean_result(res, "helper_state_apply"))
        self.refresh_status_once()

    def dump_gadget_runtime(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取辅助道具运行时倍率")
        res = self.client.lua(self.suite_code("gadget_runtime_status", self.build_gadget_runtime_extra("status")))
        self.log(self.clean_result(res, "gadget_runtime_status"))
        self.refresh_status_once()

    def run_gadget_runtime_apply(self):
        if not messagebox.askyesno("确认写入", "这只改当前进程里的辅助道具倍率，重启游戏通常会恢复。\n留空的项目不会改。"):
            return
        self.run_bg(self.apply_gadget_runtime)

    def apply_gadget_runtime(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("应用辅助道具运行时倍率")
        res = self.client.lua(self.suite_code("gadget_runtime_apply", self.build_gadget_runtime_extra("apply")))
        self.log(self.clean_result(res, "gadget_runtime_apply"))
        self.refresh_status_once()

    def dump_experimental_runtime(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("读取实验运行时")
        res = self.client.lua(self.suite_code("experimental_runtime_status", self.build_experimental_runtime_extra("status")))
        self.log(self.clean_result(res, "experimental_runtime_status"))
        self.refresh_status_once()

    def run_experimental_runtime_apply(self):
        if not messagebox.askyesno("确认写入", "这是实验运行时字段，只改当前进程，重启游戏通常恢复。\n留空的项目不会改。"):
            return
        self.run_bg(self.apply_experimental_runtime)

    def apply_experimental_runtime(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        self.log("应用实验运行时")
        res = self.client.lua(self.suite_code("experimental_runtime_apply", self.build_experimental_runtime_extra("apply")))
        self.log(self.clean_result(res, "experimental_runtime_apply"))
        self.refresh_status_once()

    def dump_symbol_chances(self, force_live: bool = False):
        ticket_id = self.current_ticket_id()
        source = "实时内存" if force_live else "缓存优先"
        self.log(f"读取几率（{source}）：{self.ticket_var.get()} / {ticket_id}")
        cached = None if force_live else self.format_cached_symbol_table(ticket_id)
        if cached:
            self.log(cached)
            return
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        extra = f"SCRITCHY_SYMBOL_TICKET={self.lua_quote(ticket_id)}"
        res = self.client.lua(self.suite_code("symbol_dump", extra))
        self.log(self.clean_result(res, "symbol_dump"))

    def run_sjp_chance_apply(self):
        if not messagebox.askyesno("确认写入", "这会修改当前进程里的超级头奖权重，重启游戏会恢复。\n留空不会写入。"):
            return
        self.run_bg(self.apply_sjp_chance)

    def apply_sjp_chance(self):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        text = self.sjp_chance_var.get().strip()
        if not text:
            self.log("SJP 权重为空：不写入。")
            return
        value = float(text)
        extra = f"SJP_CHANCE_VALUE={value}"
        self.log(f"应用 SJP 权重：{value}")
        res = self.client.lua(self.suite_code("sjp_max", extra))
        self.log(self.clean_result(res, "sjp_max"))
        if self.result_ok(res):
            self.keep_sjp_enabled.set(True)
        self.refresh_status_once()

    def run_symbol_apply(self, dryrun: bool = False):
        if not dryrun and not messagebox.askyesno("确认写入", "这会修改当前游戏内这张刮刮卡的符号权重。\n改动通常影响后续新生成的刮刮卡。"):
            return
        self.run_bg(lambda: self.apply_symbol_chances(dryrun))

    def apply_symbol_chances(self, dryrun: bool = False):
        self.ensure_connected()
        if self.auto_attach_enabled.get():
            self.attach_game()
        ticket_id = self.current_ticket_id()
        symbol = self.extract_symbol_id(self.symbol_name_var.get().strip())
        weight_text = self.weight_var.get().strip()
        if not weight_text:
            self.log("目标权重为空：不写入。")
            return
        weight = float(weight_text)
        mode = "预览几率" if dryrun else "应用几率"
        self.log(f"{mode}：票={self.ticket_var.get()} / {ticket_id} 符号={self.display_symbol(symbol) if symbol else self.symbol_type_var.get()} 权重={weight}")
        res = self.client.lua(self.suite_code("symbol_apply", self.build_symbol_extra(dryrun)))
        self.log(self.clean_result(res, "symbol_apply"))
        if not dryrun and self.result_ok(res):
            self.keep_symbol_enabled.set(True)

    def refresh_status_once(self):
        res = self.client.lua("local pid=getOpenedProcessID(); return '已连接，游戏 PID='..tostring(pid)")
        text = res.get("result") if isinstance(res, dict) else str(res)
        self.status.set(text or "已连接")

    def refresh_status(self):
        def worker():
            try:
                self.ensure_connected()
                pid = self.find_game_pid()
                if self.auto_attach_enabled.get() and pid and pid != self.last_attached_pid:
                    self.attach_game()
                elif pid:
                    self.refresh_status_once()
                else:
                    self.status.set("CE 已连接；等待游戏启动")
            except TimeoutError:
                self.status.set("CE 管道忙；后台状态下轮再试")
            except Exception:
                self.status.set("未连接 CE；可点一键准备")
            finally:
                self.after(4000, self.refresh_status)
        threading.Thread(target=worker, daemon=True).start()

    def keep_values_loop(self):
        if self.keep_values_enabled.get() and not self.keep_busy and not self.busy:
            threading.Thread(target=self._keep_values_worker, daemon=True).start()
        self.after(6000, self.keep_values_loop)

    def _keep_values_worker(self):
        self.keep_busy = True
        try:
            self.ensure_connected()
            pid = self.find_game_pid()
            if not pid:
                return
            if pid != self.last_attached_pid:
                self.attach_game()
            actions = [
                ("scratch_apply", self.build_scratch_extra("apply")),
                ("subscription_runtime_apply", self.build_subscription_runtime_extra("apply")),
                ("gadget_runtime_apply", self.build_gadget_runtime_extra("apply")),
            ]
            if self.keep_persistent_enabled.get():
                actions.extend([
                    ("custom_save_fields", self.build_custom_save_extra()),
                    ("bot_upgrade_apply", self.build_bot_extra("apply")),
                    ("single_perk_apply", self.build_single_perk_extra("apply")),
                    ("subscription_bot_apply", self.build_subscription_bot_extra("apply")),
                    ("helper_upgrade_apply", self.build_helper_upgrade_extra("apply")),
                    ("ticket_progress_apply", self.build_ticket_progress_extra("apply")),
                    ("loan_apply", self.build_loan_extra("apply")),
                    ("helper_state_apply", self.build_helper_state_extra("apply")),
                ])
            if self.keep_sjp_enabled.get() and self.sjp_chance_var.get().strip():
                actions.append(("sjp_max", f"SJP_CHANCE_VALUE={self.lua_number_or_nil(self.sjp_chance_var.get())}"))
            if self.keep_symbol_enabled.get():
                actions.append(("symbol_apply", self.build_symbol_extra(dryrun=False)))
            if self.keep_free_enabled.get():
                actions.append(("free_enable", ""))
            if self.keep_rng_enabled.get():
                actions.append(("rng_enable", ""))
            ok_count = 0
            failed = []
            for action, extra in actions:
                res = self.client.lua(self.suite_code(action, extra))
                if self.result_ok(res):
                    ok_count += 1
                else:
                    failed.append(action)
                    self.log(f"自动重应用失败：{action} -> {self.clean_result(res, action)}")
            if failed:
                self.set_status(f"保持部分失败：{len(failed)} 项，游戏 PID={pid}")
            else:
                self.set_status(f"保持已应用：{ok_count} 项，游戏 PID={pid}")
        except Exception as exc:
            self.set_status(f"保持失败：{exc}")
        finally:
            self.keep_busy = False

    def current_ticket_id(self) -> str:
        selected = self.ticket_var.get().strip()
        return TICKET_DISPLAY.get(selected, selected)

    @staticmethod
    def extract_symbol_id(text: str) -> str:
        match = re.search(r"（([^（）]+)）$", text)
        if not match:
            return text
        value = match.group(1)
        if "，" in value:
            value = value.rsplit("，", 1)[-1]
        return value.strip()

    @staticmethod
    def display_symbol(symbol_id: str) -> str:
        if not symbol_id:
            return ""
        base = symbol_id
        for suffix in ("_QC", "_SD", "_DJ", "_SJP", "_Slot", "_BP"):
            base = base.replace(suffix, "")
        base = re.sub(r"_Death_\d+$", "", base)
        base = re.sub(r"_\d+$", "", base)
        base = base.replace("_", " ")
        parts = re.findall(r"[A-Z]?[a-z]+|[A-Z]+(?=[A-Z]|$)|\d+", base)
        if not parts:
            parts = base.split()
        translated = []
        changed = False
        for part in parts:
            zh = SYMBOL_WORDS.get(part, part)
            changed = changed or zh != part
            translated.append(zh)
        display = "".join(translated) if changed else base
        return f"{display}（猜译，{symbol_id}）" if display != symbol_id else symbol_id

    @staticmethod
    def lua_quote(text: str) -> str:
        return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"

    @staticmethod
    def result_ok(res) -> bool:
        text = str(res.get("result", "") if isinstance(res, dict) else res)
        stripped = App.strip_rpc_prefix(text)
        return text.startswith("true ::") and "ERR" not in stripped and "error" not in stripped.lower()

    def sync_keep_flags_after_action(self, action_key: str, res):
        if not self.result_ok(res):
            return
        if action_key == "free_enable":
            self.keep_free_enabled.set(True)
        elif action_key == "free_disable":
            self.keep_free_enabled.set(False)
        elif action_key == "rng_enable":
            self.keep_rng_enabled.set(True)
        elif action_key == "rng_disable":
            self.keep_rng_enabled.set(False)

    def build_symbol_extra(self, dryrun: bool = False) -> str:
        ticket_id = self.current_ticket_id()
        symbol = self.extract_symbol_id(self.symbol_name_var.get().strip())
        stype = SYMBOL_TYPES.get(self.symbol_type_var.get(), "")
        weight_text = self.weight_var.get().strip()
        if not weight_text:
            raise ValueError("目标权重为空")
        weight = float(weight_text)
        luck_index = int(self.luck_index_var.get().strip())
        extra_lines = [
            f"SCRITCHY_SYMBOL_TICKET={self.lua_quote(ticket_id)}",
            f"SCRITCHY_SYMBOL_VALUE={weight}",
            f"SCRITCHY_SYMBOL_LUCK_INDEX={luck_index}",
            f"SCRITCHY_SYMBOL_DRYRUN={'true' if dryrun else 'false'}",
        ]
        if symbol:
            extra_lines.append(f"SCRITCHY_SYMBOL_ID={self.lua_quote(symbol)}")
        elif stype:
            extra_lines.append(f"SCRITCHY_SYMBOL_TYPE={stype}")
        else:
            raise ValueError("符号名字为空时，必须选择一个符号类别")
        return "\n".join(extra_lines)

    def build_subscription_bot_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_SUB_BOT_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_SUB_BOT_UNLOCK={self.lua_number_or_nil(self.sub_bot_unlock_var.get())}",
            f"SCRITCHY_BUYING_SPEED={self.lua_number_or_nil(self.buying_speed_var.get())}",
        ])

    def build_subscription_runtime_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_SUB_RUNTIME_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_SUB_PROCESSING_DURATION={self.lua_number_or_nil(self.sub_processing_duration_var.get())}",
            f"SCRITCHY_SUB_MAX_TICKET_COUNT={self.lua_number_or_nil(self.sub_max_ticket_count_var.get())}",
            f"SCRITCHY_SUB_PAUSED={self.lua_number_or_nil(self.sub_paused_var.get())}",
            f"SCRITCHY_SUB_PROCESSING_SPEED_MULT={self.lua_number_or_nil(self.sub_processing_speed_var.get())}",
        ])

    def build_helper_upgrade_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_HELPER_UPGRADE_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_UPGRADE_FAN={self.lua_number_or_nil(self.helper_fan_var.get())}",
            f"SCRITCHY_UPGRADE_FAN_SPEED={self.lua_number_or_nil(self.helper_fan_speed_var.get())}",
            f"SCRITCHY_UPGRADE_FAN_BATTERY={self.lua_number_or_nil(self.helper_fan_battery_var.get())}",
            f"SCRITCHY_UPGRADE_MUNDO={self.lua_number_or_nil(self.helper_mundo_var.get())}",
            f"SCRITCHY_UPGRADE_MUNDO_SPEED={self.lua_number_or_nil(self.helper_mundo_speed_var.get())}",
            f"SCRITCHY_UPGRADE_SPELL_BOOK={self.lua_number_or_nil(self.helper_spell_book_var.get())}",
            f"SCRITCHY_UPGRADE_SPELL_CHARGE_SPEED={self.lua_number_or_nil(self.helper_spell_charge_var.get())}",
            f"SCRITCHY_UPGRADE_EGG_TIMER={self.lua_number_or_nil(self.helper_egg_timer_var.get())}",
            f"SCRITCHY_UPGRADE_TIMER_CAPACITY={self.lua_number_or_nil(self.helper_timer_capacity_var.get())}",
            f"SCRITCHY_UPGRADE_TIMER_CHARGE={self.lua_number_or_nil(self.helper_timer_charge_var.get())}",
            f"SCRITCHY_UPGRADE_WARP_SPEED={self.lua_number_or_nil(self.helper_warp_speed_var.get())}",
        ])

    def build_ticket_progress_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_TICKET_PROGRESS_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_TICKET_ID={self.lua_quote(self.current_progress_ticket_id())}",
            f"SCRITCHY_TICKET_LEVEL={self.lua_number_or_nil(self.progress_level_var.get())}",
            f"SCRITCHY_TICKET_XP={self.lua_number_or_nil(self.progress_xp_var.get())}",
        ])

    def build_loan_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_LOAN_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_LOAN_COUNT={self.lua_number_or_nil(self.loan_count_var.get())}",
            f"SCRITCHY_LOAN_LIST_SIZE={self.lua_number_or_nil(self.loan_list_size_var.get())}",
            f"SCRITCHY_LOAN_INDEX={self.lua_number_or_nil(self.loan_index_var.get())}",
            f"SCRITCHY_LOAN_NUM={self.lua_number_or_nil(self.loan_num_var.get())}",
            f"SCRITCHY_LOAN_SEVERITY={self.lua_number_or_nil(self.loan_severity_var.get())}",
            f"SCRITCHY_LOAN_AMOUNT={self.lua_number_or_nil(self.loan_amount_var.get())}",
        ])

    def build_single_perk_extra(self, mode: str) -> str:
        target = self.single_perk_target_var.get().strip()
        if mode == "apply" and not target:
            raise ValueError("能力名为空")
        return "\n".join([
            f"SCRITCHY_SINGLE_PERK_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_SINGLE_PERK_TARGET={self.lua_quote(target)}",
            f"SCRITCHY_SINGLE_PERK_COUNT={self.lua_number_or_nil(self.single_perk_count_var.get())}",
        ])

    def build_helper_state_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_HELPER_STATE_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_ELECTRIC_FAN_CHARGE_LEFT={self.lua_number_or_nil(self.electric_fan_charge_var.get())}",
            f"SCRITCHY_FAN_PAUSED={self.lua_number_or_nil(self.fan_paused_var.get())}",
            f"SCRITCHY_EGG_TIMER_CHARGE_LEFT={self.lua_number_or_nil(self.egg_timer_charge_left_var.get())}",
            f"SCRITCHY_MUNDO_DEAD={self.lua_number_or_nil(self.mundo_dead_var.get())}",
            f"SCRITCHY_TRASH_CAN_DEAD={self.lua_number_or_nil(self.trash_can_dead_var.get())}",
        ])

    def build_gadget_runtime_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_GADGET_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_EGGTIMER_BATTERY_CAPACITY_MULT={self.lua_number_or_nil(self.eggtimer_capacity_var.get())}",
            f"SCRITCHY_EGGTIMER_BATTERY_CHARGE_MULT={self.lua_number_or_nil(self.eggtimer_charge_var.get())}",
            f"SCRITCHY_EGGTIMER_MULT_MULTIPLIER={self.lua_number_or_nil(self.eggtimer_mult_var.get())}",
            f"SCRITCHY_FAN_BATTERY_CAPACITY_MULT={self.lua_number_or_nil(self.fan_capacity_var.get())}",
            f"SCRITCHY_FAN_BATTERY_CHARGE_MULT={self.lua_number_or_nil(self.fan_charge_var.get())}",
            f"SCRITCHY_FAN_SPEED_MULT={self.lua_number_or_nil(self.fan_speed_var.get())}",
            f"SCRITCHY_MUNDO_CLAIM_SPEED_MULT={self.lua_number_or_nil(self.mundo_claim_speed_var.get())}",
            f"SCRITCHY_SCRATCHBOT_SPEED_MULT={self.lua_number_or_nil(self.scratchbot_speed_mult_var.get())}",
            f"SCRITCHY_SCRATCHBOT_EXTRA_SPEED={self.lua_number_or_nil(self.scratchbot_extra_speed_var.get())}",
            f"SCRITCHY_SCRATCHBOT_EXTRA_CAPACITY={self.lua_number_or_nil(self.scratchbot_extra_capacity_var.get())}",
            f"SCRITCHY_SCRATCHBOT_EXTRA_STRENGTH={self.lua_number_or_nil(self.scratchbot_extra_strength_var.get())}",
            f"SCRITCHY_SPELLBOOK_RECHARGE_SPEED_MULT={self.lua_number_or_nil(self.spellbook_recharge_var.get())}",
        ])

    def build_experimental_runtime_extra(self, mode: str) -> str:
        return "\n".join([
            f"SCRITCHY_EXPERIMENTAL_MODE={self.lua_quote(mode)}",
            f"SCRITCHY_SCRATCHBOT_PROCESSING_DURATION={self.lua_number_or_nil(self.scratchbot_processing_duration_var.get())}",
            f"SCRITCHY_MUNDO_PAUSED={self.lua_number_or_nil(self.mundo_paused_runtime_var.get())}",
        ])

    def clean_result(self, res, action_key: str = "") -> str:
        raw = str(res.get("result", "") if isinstance(res, dict) else res)
        if self.verbose_log.get():
            return raw
        text = self.strip_rpc_prefix(raw)
        if action_key == "dump":
            return self.summarize_dump(text)
        if action_key == "dump_perks":
            return self.summarize_perks(text)
        if action_key in {"symbol_dump", "symbol_apply"}:
            return self.summarize_symbols(text, action_key)
        if action_key in {"perk_boost_dryrun", "perk_boost_apply"}:
            return self.summarize_perk_boost(text, action_key)
        if action_key in {"automation_perks_status", "automation_perks_apply"}:
            return self.summarize_automation_perks(text, action_key)
        if action_key == "runtime_status":
            return self.summarize_runtime_status(text)
        if action_key in {"custom_save_fields", "scratch_status", "scratch_apply", "bot_upgrade_status", "bot_upgrade_apply", "single_perk_status", "single_perk_apply", "subscription_bot_status", "subscription_bot_apply", "subscription_runtime_status", "subscription_runtime_apply", "helper_upgrade_status", "helper_upgrade_apply", "ticket_progress_status", "ticket_progress_apply", "loan_status", "loan_apply", "loan_clear", "helper_state_status", "helper_state_apply", "gadget_runtime_status", "gadget_runtime_apply", "experimental_runtime_status", "experimental_runtime_apply", "sjp_max"}:
            return self.summarize_key_values(text, action_key)
        return self.summarize_generic(text)

    @staticmethod
    def strip_rpc_prefix(text: str) -> str:
        for prefix in ("true :: true :: ", "true :: "):
            if text.startswith(prefix):
                return text[len(prefix):]
        return text

    @staticmethod
    def summarize_dump(text: str) -> str:
        lines = text.splitlines()
        get = lambda key: next((line for line in lines if key in line), "")
        save = get("SaveData fields")
        layer = get("LayerOne ptrs")
        managers = [name for name in ("PerkManager", "DebugTools", "TicketShop", "PlayerWallet", "TicketProgressionManager") if any(name in line for line in lines)]
        parts = ["游戏数据状态：OK"]
        if save:
            parts.append(save.replace("SaveData fields ", "存档字段："))
        if layer:
            parts.append("核心容器：票进度、奖池、自定义物品已识别")
        if managers:
            parts.append("已识别管理器：" + "、".join(dict.fromkeys(managers)))
        return "\n".join(parts)

    @staticmethod
    def summarize_perks(text: str) -> str:
        rows = [line.split("\t") for line in text.splitlines() if "\t" in line and not line.startswith("type\t")]
        if not rows:
            return text
        names = []
        for row in rows[:10]:
            if len(row) >= 9:
                names.append(f"{row[6]}={row[8]}")
        more = "" if len(rows) <= 10 else f"\n还有 {len(rows)-10} 个未展开；勾选详细输出可看全量。"
        return f"当前能力：{len(rows)} 个\n" + "、".join(names) + more

    @staticmethod
    def summarize_symbols(text: str, action_key: str) -> str:
        lines = text.splitlines()
        rows = []
        for line in lines:
            cols = line.split("\t")
            if len(cols) == 6 and cols[0] != "ticket":
                rows.append(cols)
        if rows:
            ticket = rows[0][0]
            out = [f"{ticket} 当前符号权重："]
            for _, symbol, _stype, type_name, _count, chances in rows:
                out.append(f"- {App.display_symbol(symbol)}（{type_name}）：{chances}")
            return "\n".join(out)
        if action_key == "symbol_apply" and "OK touchedSymbols" in text:
            changed = next((line for line in lines if line.startswith("OK touchedSymbols")), "OK")
            detail = [line for line in lines if " -> " in line]
            touched_symbols = re.search(r"touchedSymbols=(\d+)", changed)
            touched_floats = re.search(r"touchedFloats=(\d+)", changed)
            title = "符号权重已应用"
            parts = []
            if touched_symbols:
                parts.append(f"符号 {touched_symbols.group(1)} 个")
            if touched_floats:
                parts.append(f"幸运等级 {touched_floats.group(1)} 格")
            out = [title + ("：" + "，".join(parts) if parts else "。")]
            for line in detail[:3]:
                friendly = re.sub(r"\s+type=-?\d+\s+", " ", line)
                friendly = re.sub(r"\s+changed=(\d+)\s+err=nil", r"（已写入 \1 格，无错误）", friendly)
                friendly = re.sub(r"\s+changed=(\d+)\s+err=([^\s]+)", r"（已尝试写入 \1 格，错误：\2）", friendly)
                out.append(friendly)
            return "\n".join(out)
        return text

    @staticmethod
    def summarize_perk_boost(text: str, action_key: str) -> str:
        ok = next((line for line in text.splitlines() if line.startswith("OK seen=")), "OK")
        title = "能力升级预览完成" if action_key == "perk_boost_dryrun" else "能力已升级并同步存档"
        return f"{title}：{ok}"

    @staticmethod
    def summarize_automation_perks(text: str, action_key: str) -> str:
        lines = [line for line in text.splitlines() if line.strip()]
        title = "自动化能力状态" if action_key == "automation_perks_status" else "自动化能力已处理"
        useful = []
        for line in lines:
            if "Fully Automated" in line:
                useful.append(line.replace("Fully Automated", "Fully Automated / 订阅机器人开局能力"))
            elif "HandsOff" in line:
                useful.append(line.replace("HandsOff", "HandsOff / 自动刮卡能力"))
            elif line.startswith("OK "):
                useful.append(line)
        if not useful:
            useful = lines[:6]
        return title + "：\n" + "\n".join(useful[:8])

    @staticmethod
    def summarize_runtime_status(text: str) -> str:
        lines = [line for line in text.splitlines() if line.strip()]
        if not lines:
            return "运行时状态读取完成，但没有返回内容。"
        friendly = []
        for line in lines:
            if line.startswith("存档:"):
                friendly.append("存档状态：" + line.split("存档:", 1)[1].strip())
            elif line.startswith("资源:"):
                friendly.append("资源状态：" + line.split("资源:", 1)[1].strip())
            elif line.startswith("刮卡:"):
                friendly.append("刮卡状态：" + line.split("刮卡:", 1)[1].strip())
            elif line.startswith("当前票:"):
                friendly.append("当前票：" + line.split("当前票:", 1)[1].strip())
            elif line.startswith("超级头奖:"):
                friendly.append("超级头奖：" + line.split("超级头奖:", 1)[1].strip())
        return "运行时状态：\n" + "\n".join(friendly or lines[:6])

    @staticmethod
    def summarize_key_values(text: str, action_key: str) -> str:
        lines = [line for line in text.splitlines() if line.strip()]
        title_map = {
            "custom_save_fields": "运行时存档数值已处理",
            "scratch_status": "刮卡/Bot 参数读取完成",
            "scratch_apply": "刮卡/Bot 参数已应用",
            "bot_upgrade_status": "刮刮机器人升级读取完成",
            "bot_upgrade_apply": "刮刮机器人升级已应用",
            "single_perk_status": "单个能力读取完成",
            "single_perk_apply": "单个能力等级已应用",
            "subscription_bot_status": "订阅机器人升级读取完成",
            "subscription_bot_apply": "订阅机器人升级已应用",
            "subscription_runtime_status": "订阅机器人运行时读取完成",
            "subscription_runtime_apply": "订阅机器人运行时已应用",
            "helper_upgrade_status": "辅助道具升级读取完成",
            "helper_upgrade_apply": "辅助道具升级已应用",
            "ticket_progress_status": "单票进度读取完成",
            "ticket_progress_apply": "单票进度已应用",
            "loan_status": "贷款状态读取完成",
            "loan_apply": "贷款字段已应用",
            "loan_clear": "贷款已清空",
            "helper_state_status": "辅助状态读取完成",
            "helper_state_apply": "辅助状态救援已应用",
            "gadget_runtime_status": "辅助道具倍率读取完成",
            "gadget_runtime_apply": "辅助道具倍率已应用",
            "experimental_runtime_status": "实验运行时读取完成",
            "experimental_runtime_apply": "实验运行时已应用",
            "sjp_max": "SJP 权重已应用",
        }
        title = title_map.get(action_key, "操作完成")
        if action_key == "sjp_max":
            target = re.search(r"targetValue=([^\s]+)", text)
            boosted = re.search(r"boosted=(\d+)", text)
            parts = []
            if target:
                parts.append(f"目标权重={target.group(1)}")
            if boosted:
                parts.append(f"已更新 live 对象={boosted.group(1)}")
            return title + ("：" + "，".join(parts) if parts else "。")
        useful = [line for line in lines if " -> " in line or line.startswith("no fields") or line.endswith("not_found")]
        if not useful:
            useful = lines[1:6] if len(lines) > 1 else lines[:5]
        if len(useful) > 8:
            useful = useful[:8] + [f"……共 {len(lines)} 行，勾选详细输出可看全量。"]
        return title + "：\n" + "\n".join(useful)

    @staticmethod
    def summarize_generic(text: str):
        lines = [line for line in text.splitlines() if line.strip()]
        if not lines:
            return "完成。"
        ok_line = next((line for line in reversed(lines) if line.startswith("OK") or " OK " in line or line.startswith("base=") or line.startswith("SaveData")), None)
        if ok_line:
            return "完成：" + ok_line
        if len(lines) > 6:
            return "完成。摘要：\n" + "\n".join(lines[:5]) + f"\n……共 {len(lines)} 行，勾选详细输出可看全量。"
        return "完成：" + "\n".join(lines)

    def destroy(self):
        self.client.close()
        super().destroy()

if __name__ == "__main__":
    App().mainloop()
