# Scritchy Scratchy Progress Index 2026-04-25

## Verified live pointer-chain persistence
- Pointer chain doc: analysis/pointer_chains_2026-04-25.md
- Read-only resolver: ce_scripts/dump_pointer_chains.lua
- Online persistence script: ce_scripts/online_persist_unlock.lua
- Verification: analysis/online_persistence_2026-04-25.md

## Current live-safe features
- Full ticket progression: 43 existing TicketProgressionData objects updated in memory to level=30/xp=9999.
- Autosave persistence: save.json and latest AutoSave persisted minL=30/maxL=30/minXp=9999.
- Jackpot history: jackpotsGotten already covers 17 normal non-Final main tickets.
- SJP history: superJackpotsGotten currently mirrors jackpotsGotten List<string>, persisted 17 entries.
- Economy gates: prestige=99, currentAct=5, tokens=999999999, money=1e40, souls=999999.

## Ticket map from agent team
- Total progression entries: 43.
- Normal main tickets: 18 including Day Job and Two Win..Booster Pack.
- Final main tickets: Final Chance, Final Chance_2, Final Chance_3, Final Chance_4, Final Chance_Win.
- Special tickets: Loan plus Super_* and Super_Final Chance_Win.
- Catalogs: Act 1/Upgrade/Act 2/Act 3/Act 4 already claimed.
- Known prices:
  - Day Job: 1 catalog0
  - Act1: Two Win 10, Mini Scratch 100, Apple Tree 2000, Quick Cash 10000, Lucky Cat 300000, Final Chance 50000000
  - Act2: Sand Dollars 20000000, Scratch My Back 500000000, Snake Eyes 10000000000, The Bomb 200000000000, Final Chance_2 5000000000000
  - Act3: Bank Break 200000000000000, Xmas Countdown 1e16, Thrift Store 5e17, Berry Picking 2e19, Final Chance_3 1e21
  - Act4: Trick or Treat 6e22, Slot Machine 5e24, To the Moon 8e26, Booster Pack 3e28, Final Chance_4 1e30

## Container rules
- List<T>: items +0x10, size +0x18, version +0x1C; array length at items +0x18; first element at items +0x20.
- Dictionary<string, TicketProgressionData>: entries +0x18; entry stride 0x18; hash +0x00, key +0x08, value +0x10.
- Safe update: write existing TicketProgressionData xp +0x18 and level +0x1C only.
- Safe List<string> append: reuse existing managed string pointer, append only if size < capacity, then size++ and version++.
- Unsafe: manual Dictionary/List expansion, fake managed strings/tuples, ActivatePerk executeMethod, unverified DebugTools native calls.

## Next implementation targets
1. Keep default safe matrix green at `36/36` before adding more runtime fields.
2. Investigate machine processing and income fields read-only first, then add write-after-restore only if stable.
3. Build independent `superJackpotsGotten` list expansion using a real managed API or verified safe allocation.
4. Continue DebugTools hidden-entry mapping without enabling native calls by default.
5. Keep `UnityEngine.Time.timeScale` out of default GUI until an isolated timeout/recovery runner exists.

## DebugTools agent-team findings
- Start registers Debug buttons through SpawnDebugButton(text, callback, shortcut, spawnHidden).
- Strong button text anchors: Add Super Jackpot, Tokens, Hide mult label, Unlock Tickets, Simulate Ticket, Skip a catalogue.
- SaveScreenshot has Screenshots/Screenshot path anchors and is likely hidden/shortcut-only.
- Shortcut predicates are closure-based and involve Ctrl, Shift, Pressed(KeyControl); exact key mapping still needs native disasm.
- Safe substitutes:
  - Tokens -> SaveData/tokens field chain.
  - Skip act -> SaveData.currentAct + prestigeCurrency fields.
  - Unlock tickets -> ticketProgressionDict + lastTicketUnlocked fields.
  - Hide multiplier -> DebugTools.HideTicketMultLabel +0x92 or Ticket display path.
  - Simulate -> DebugTools.IsSimulating +0x91, but avoid driving generation loops for now.
- Unsafe native calls by default: AddSuperJackpotChanceToTicket, UnlockAllTickets, SkipToAct, ToggleSimulateTicket, SpawnDebugButton/Start/HandleDebugShortcuts.
- Next only-read deepening: disassemble GameAssembly RVAs 0x491CD0, 0x491FE0, 0x4923B0, 0x4924C0, 0x492640, 0x4928E0, 0x493660.
