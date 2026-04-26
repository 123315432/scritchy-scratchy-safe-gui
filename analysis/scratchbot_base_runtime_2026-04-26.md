# ScratchBot base runtime fields - 2026-04-26

## Changed
- Added `ScratchBot.capacity +0xC4` and `ScratchBot.strength +0xC8` to the whitelisted gadget runtime dispatcher.
- Added GUI fields for current ScratchBot capacity and current ScratchBot strength under runtime helper gadgets.
- Extended `gadget_runtime_dispatcher_restore` to cover 14 fields instead of 12.

## Evidence
- `dump_il2cppdumper/dump.cs:682717` shows `ScratchBot.capacity` at `0xC4` and `ScratchBot.strength` at `0xC8`.
- `dump_il2cppdumper/il2cpp.h:381373` mirrors the same offsets.
- Runtime instance uses the existing `findInstance('ScratchBot')` pattern already used by `gadget_runtime_fields.lua`.

## Verified
- Local targeted command: `python .\scripts\scritchy_verify_api.py --shared-client --wait-ready 180 --case gadget_runtime_status --case gadget_runtime_dispatcher_restore --report .\analysis\gadget_runtime_bot_base_verify_20260426.json`
  - Result: 2/2 OK.
  - Restore details included `ScratchBot.capacity 33 -> 34 -> 33` and `ScratchBot.strength 20 -> 21 -> 20`.
- Full default safe matrix: `python .\scripts\scritchy_verify_api.py --shared-client --wait-ready 180 --report .\analysis\gui_function_verify_report_bot_base_20260426.json`
  - Result: 36/36 OK.
  - Gadget runtime restore now reports `fields=14`.

## Not yet added
- `PrestigeLayerOneData.machineProcessingTimeLeft +0x84`: low-risk candidate, but it is a process/save countdown field and should be tested separately before default GUI exposure.
- `TheMachine.processingDuration +0x20`: experimental runtime candidate, not default matrix yet.
- `MachineTierData.bonusIncome +0x20`: still read-only/static evidence only; live tier object ownership not verified.
