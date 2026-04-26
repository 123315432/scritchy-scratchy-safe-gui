-- rng_control_v2.lua
-- Simplified RNG bias: patch GetRandomWeightedIndex to always return index 0
-- (which maps to the highest-weight symbol in the weights array)
-- Strategy: NOP the call to GetRandomWeightedIndex at callsite, inject: xor eax,eax; ret
-- This forces all symbol picks to return index 0.
--
-- SymbolType: Bad=-1, Dud=0, Small=1, Jackpot=2, SuperJackpot=3, Mult=4, SelfDestruct=5
-- Typically index 0 in the weights array = highest chance symbol (varies per ticket config)
--
-- For guaranteed SuperJackpot: combine with force_symbols.lua to lock slots.
-- This script patches GetRandomWeightedIndex at RVA 0x49AAC0 to always return 0.
-- Uninstall: rerun with SCRITCHY_RNG_V2_UNINSTALL = true

openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local HELPER_RVA = 0x49AAC0  -- GetRandomWeightedIndex
local PATCH_SIZE = 6          -- xor eax,eax (2) + ret (1) + nops (3)

local UNINSTALL = (type(SCRITCHY_RNG_V2_UNINSTALL) == 'boolean' and SCRITCHY_RNG_V2_UNINSTALL)

local patchAddr = base + HELPER_RVA

local function hexOf(bytes)
  local items = {}
  for _, b in ipairs(bytes or {}) do items[#items+1] = string.format('%02X', b) end
  return table.concat(items, ' ')
end

local function readPatchBytes()
  local bytes = readBytes(patchAddr, PATCH_SIZE, true)
  if not bytes then return nil, 'cannot read bytes at ' .. string.format('0x%X', patchAddr) end
  return bytes, hexOf(bytes)
end

-- Patch bytes: xor eax,eax; ret; nop; nop; nop
local PATCH_BYTES = {0x33, 0xC0, 0xC3, 0x90, 0x90, 0x90}
local PATCH_HEX = '33 C0 C3 90 90 90'

local origBytes, origHexStr = readPatchBytes()
if not origBytes then return 'ERR: ' .. tostring(origHexStr) end
local alreadyPatched = (origHexStr == PATCH_HEX)

if UNINSTALL then
  local saved = rawget(_G, 'SCRITCHY_RNG_V2_ORIG_BYTES')
  if not saved then
    local savedAddr = getAddressSafe('ss_rng_v2_orig_bytes')
    if savedAddr and savedAddr ~= 0 then saved = readBytes(savedAddr, PATCH_SIZE, true) end
  end
  if not saved then
    if alreadyPatched then return 'UNINSTALL ERR: patched but no saved original bytes' end
    return 'UNINSTALL OK not_patched current=' .. origHexStr
  end
  writeBytes(patchAddr, saved)
  local verify, vStr = readPatchBytes()
  if vStr == hexOf(saved) then
    pcall(autoAssemble, 'unregistersymbol(ss_rng_v2_orig_bytes)')
    rawset(_G, 'SCRITCHY_RNG_V2_ORIG_BYTES', nil)
    return 'UNINSTALL OK restored=' .. vStr
  end
  return 'UNINSTALL ERR restore verify failed current=' .. tostring(vStr)
end

if alreadyPatched then
  return 'OK already_patched addr=0x' .. string.format('%X', patchAddr)
end

local savedAddr = getAddressSafe('ss_rng_v2_orig_bytes')
if savedAddr and savedAddr ~= 0 then
  pcall(autoAssemble, 'unregistersymbol(ss_rng_v2_orig_bytes)')
end

rawset(_G, 'SCRITCHY_RNG_V2_ORIG_BYTES', origBytes)
local saveOk = autoAssemble(string.format([[
globalalloc(ss_rng_v2_orig_bytes,%d)
registersymbol(ss_rng_v2_orig_bytes)
ss_rng_v2_orig_bytes:
db %s
]], PATCH_SIZE, origHexStr))

if not saveOk and not rawget(_G, 'SCRITCHY_RNG_V2_ORIG_BYTES') then
  return 'ERR: cannot save original bytes; patch refused current=' .. origHexStr
end

-- Apply patch only after Lua/global saved copy exists.
writeBytes(patchAddr, PATCH_BYTES)

-- Verify
local verify = readBytes(patchAddr, PATCH_SIZE, true)
local vhex = {}
for _, b in ipairs(verify) do vhex[#vhex+1] = string.format('%02X', b) end
local vStr = table.concat(vhex, ' ')

if vStr == PATCH_HEX then
  return string.format('OK patched addr=0x%X orig=[%s] now=[%s]', patchAddr, origHexStr, vStr)
else
  return string.format('ERR patch verify failed addr=0x%X expected=[%s] got=[%s]', patchAddr, PATCH_HEX, vStr)
end
