# Ticket Symbol Chance Control 2026-04-25

## Goal
- Add per-ticket / per-symbol live chance control.
- User-facing GUI should speak in gameplay terms: ticket, symbol, symbol category, target weight.

## Confirmed Data Path
- `StaticData` live singleton contains `ticketData` at `+0x78`.
- `StaticData.ticketData` is `Dictionary<string, TicketData>`; current live count is 43.
- `TicketData.symbols` is at `TicketData + 0x48` and points to `List<SymbolData>`.
- `SymbolData.id` is at `+0x18`.
- `SymbolData.chances` is at `+0x30` and points to `List<float>`.
- `SymbolData.type` is at `+0x38`.
- Symbol types: `-1=坏符号`, `0=空符号`, `1=小奖`, `2=大奖`, `3=超级大奖`, `4=倍率`, `5=自毁`.

## Implemented Scripts
- New script: `D:\Code\_tmp\scritchy_il2cpp\ce_scripts\ticket_symbol_chances.lua`.
- New whitelist actions in `scritchy_safe_suite.lua`:
  - `symbol_dump`: dump one ticket or all tickets symbol weights.
  - `symbol_apply`: apply weight by exact symbol id or by symbol type.

## Verified Live Output
- `symbol_dump` for `Lucky Cat` returned 5 symbols:
  - `Fishbone`, type `-1`, chances `889,500,400,250,100,50,5`.
  - `Fish`, type `0`, chances `99,389,350,400,390,200,195`.
  - `Pink Flower`, type `1`, chances `10,100,200,250,400,500,200`.
  - `Paw Print`, type `1`, chances `1,10,48,95,100,200,350`.
  - `Gold Coin`, type `2`, chances `1,1,2,5,10,50,250`.
- `symbol_apply` dry-run for `Lucky Cat / Gold Coin -> 99999` touched 1 symbol and 7 chance floats.
- `symbol_type_dryrun` for `Lucky Cat` type `1` touched `Pink Flower` and `Paw Print`; dryrun only verifies category matching and chance-slot count, without writing memory.
- No destructive apply was needed for this verification pass.

## GUI State
- GUI now groups existing actions in gameplay language:
  - 查看状态
  - 进度与资源
  - Perk 管理
  - 抽奖与概率
  - 免费购买
- New panel: `每张票的每个符号几率控制`.
- Fields:
  - 票类型
  - 符号名字
  - 符号类别
  - 目标权重
  - 幸运等级索引 (`-1` means all chance slots)
- Buttons:
  - `读取这张刮刮卡当前几率`
  - `强制实时读取`
  - `预览符号改动`
  - `应用到这张刮刮卡`

## Notes
- These are weights, not percentages. Higher weight in the same ticket pool means more frequent selection.
- Exact symbol name has priority. If symbol name is empty, GUI applies by symbol category.
- Default read uses the local symbol cache for speed; `强制实时读取` bypasses cache and reads current CE memory.
- Apply log summarizes touched symbols and touched chance slots; detailed raw output is still available through the GUI debug-output checkbox.
- Changes are live memory edits to loaded `StaticData.ticketData`; they are intended to affect newly generated tickets after the change.
- This is independent from the older RNG patch. RNG patch forces random selection index; symbol chance control edits the weighted pool itself.
