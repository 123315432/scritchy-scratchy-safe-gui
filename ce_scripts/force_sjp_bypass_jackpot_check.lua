-- Force SJP for all tickets by bypassing jackpotsGotten check
-- TryGetSuperJackpotChanceChance at RVA 0x4B08F0
-- At RVA 0x4B09EF: je 0x4b0b56 (jump if ticketID NOT in jackpotsGotten)
-- Patch: change je to jmp-to-continue (nop the conditional jump)
--
-- Original bytes at RVA 0x4B09EF: 0F 84 61 01 00 00 (je +0x161)
-- Patched bytes:                  90 90 90 90 90 90 (6x nop)

openProcess('ScritchyScratchy.exe')

-- Find GameAssembly.dll base
local base = getAddress('GameAssembly.dll')
if base == nil then
  print('ERROR: GameAssembly.dll not found')
  return
end
print('GameAssembly.dll base = 0x'..string.format('%X', base))

local patch_rva = 0x4B09EF
local patch_addr = base + patch_rva

-- Verify original bytes
local b1 = readBytes(patch_addr, 1)
local b2 = readBytes(patch_addr + 1, 1)
print(string.format('Original bytes at RVA 0x%X: %02X %02X', patch_rva, b1, b2))

if b1 == 0x0F and b2 == 0x84 then
  -- je -> 6x nop
  writeBytes(patch_addr, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90)
  local v1 = readBytes(patch_addr, 1)
  local v2 = readBytes(patch_addr + 1, 1)
  print(string.format('Patched! Verify: %02X %02X (should be 90 90)', v1, v2))
  print('SUCCESS: TryGetSuperJackpotChanceChance will now always proceed for ALL tickets')
  print('Buy a Lucky Cat ticket and scratch to test!')
else
  print('WARNING: Bytes do not match expected je instruction')
  print('The game version may have changed, or base address is wrong')
  print('Dumping 10 bytes around the patch point:')
  for i = -4, 10 do
    local b = readBytes(patch_addr + i, 1)
    print(string.format('  RVA 0x%X: %02X', patch_rva + i, b))
  end
end
