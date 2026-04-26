from __future__ import annotations
import argparse, json, os, shutil, time
from pathlib import Path

DEFAULT_SAVE_DIR = Path(os.environ.get('USERPROFILE', '~')).expanduser() / 'AppData' / 'LocalLow' / 'Lunch Money Games' / 'Scritchy Scratchy'
DEFAULT_SAVE_FILE = DEFAULT_SAVE_DIR / 'save.json'
MAIN_TICKETS = [
    'Two Win','Mini Scratch','Apple Tree','Quick Cash','Lucky Cat','Sand Dollars','Scratch My Back','Snake Eyes','The Bomb',
    'Bank Break','Xmas Countdown','Thrift Store','Berry Picking','Trick or Treat','Slot Machine','To the Moon','Booster Pack'
]
SPECIAL_TICKETS = ['Final Chance','Final Chance_2','Final Chance_3','Final Chance_4','Final Chance_Win']
SUPER_TICKETS = [f'Super_{name}' for name in MAIN_TICKETS] + ['Super_Final Chance_Win']
ALL_PROGRESS_TICKETS = ['Loan','Day Job'] + MAIN_TICKETS[:5] + ['Final Chance'] + MAIN_TICKETS[5:9] + ['Final Chance_2'] + MAIN_TICKETS[9:13] + ['Final Chance_3'] + MAIN_TICKETS[13:] + ['Final Chance_4','Final Chance_Win'] + [f'Super_{name}' for name in ['Day Job'] + MAIN_TICKETS] + ['Super_Final Chance_Win']
CATALOG_ITEMS = ['Act 1 Catalog','Upgrade Catalog','Act 2 Catalog','Act 3 Catalog','Act 4 Catalog']

def load_save(path: Path) -> dict:
    return json.loads(path.read_text(encoding='utf-8-sig'))

def write_save(path: Path, data: dict) -> Path:
    stamp = time.strftime('%Y%m%d_%H%M%S')
    backup = path.with_name(path.name + f'.bak_full_unlock_{stamp}')
    shutil.copy2(path, backup)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    return backup

def ensure_progress(layer_one: dict, level: int, xp: int) -> None:
    progress = layer_one.setdefault('ticketProgressionDict', {})
    for ticket_id in ALL_PROGRESS_TICKETS:
        item = progress.setdefault(ticket_id, {})
        item['id'] = ticket_id
        item['xp'] = max(int(item.get('xp', 0) or 0), xp)
        item['level'] = max(int(item.get('level', 0) or 0), level)

def unique_extend(values: list, additions: list[str]) -> list:
    seen = set(values)
    out = list(values)
    for item in additions:
        if item not in seen:
            out.append(item)
            seen.add(item)
    return out

def apply(data: dict, level: int, xp: int) -> dict:
    layer_one = data.setdefault('layerOne', {})
    data['prestigeCount'] = max(int(data.get('prestigeCount', 0) or 0), 99)
    data['prestigeCurrency'] = max(int(data.get('prestigeCurrency', 0) or 0), 999999)
    data['currentAct'] = max(int(data.get('currentAct', 0) or 0), 5)
    data['tokens'] = max(float(data.get('tokens', 0) or 0), 999999999.0)
    layer_one['money'] = max(float(layer_one.get('money', 0) or 0), 1e40)
    layer_one['souls'] = max(int(layer_one.get('souls', 0) or 0), 999999)
    layer_one['lastUnlockedProgressionGoal'] = max(float(layer_one.get('lastUnlockedProgressionGoal', 0) or 0), 1e30)
    layer_one['claimedCustomTableItems'] = unique_extend(layer_one.get('claimedCustomTableItems', []), CATALOG_ITEMS)
    layer_one['jackpotsGotten'] = unique_extend(layer_one.get('jackpotsGotten', []), MAIN_TICKETS)
    layer_one['superJackpotsGotten'] = unique_extend(layer_one.get('superJackpotsGotten', []), MAIN_TICKETS + SUPER_TICKETS)
    layer_one['lastTicketUnlocked'] = 'Final Chance_4'
    ensure_progress(layer_one, level, xp)
    return data

def summarize(data: dict) -> str:
    lo = data.get('layerOne', {})
    prog = lo.get('ticketProgressionDict', {})
    return '\n'.join([
        f"tickets={len(prog)} minLevel={min((v.get('level', 0) for v in prog.values()), default=0)} maxLevel={max((v.get('level', 0) for v in prog.values()), default=0)}",
        f"jackpots={len(lo.get('jackpotsGotten', []))} superJackpots={len(lo.get('superJackpotsGotten', []))}",
        f"catalogs={len(lo.get('claimedCustomTableItems', []))} lastTicketUnlocked={lo.get('lastTicketUnlocked')}",
        f"tokens={data.get('tokens')} money={lo.get('money')} souls={lo.get('souls')} act={data.get('currentAct')}",
    ])

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--level', type=int, default=30)
    parser.add_argument('--xp', type=int, default=9999)
    parser.add_argument('--save-file', type=Path, default=DEFAULT_SAVE_FILE)
    args = parser.parse_args()
    save_file = args.save_file.expanduser()
    data = load_save(save_file)
    print('BEFORE')
    print(summarize(data))
    new_data = apply(data, args.level, args.xp)
    print('AFTER')
    print(summarize(new_data))
    if args.apply:
        backup = write_save(save_file, new_data)
        print(f'WROTE {save_file}')
        print(f'BACKUP {backup}')
    else:
        print('DRYRUN only; pass --apply to write')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
