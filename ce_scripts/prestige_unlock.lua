-- prestige_unlock.lua
-- Usage:
--   1. Attach Cheat Engine to ScritchyScratchy.exe
--   2. Run this Lua script once
-- Behavior:
--   - Resolves SaveData.get_Current()
--   - Pushes current save into an endgame-like prestige state
--   - Writes layerOne money / souls / progression gate fields
--   - Sets currentAct to max act
--   - Sets prestige currency / death count / tokens high
--   - Activates all known PerkType values used by current build
-- Notes:
--   - Current build exposes only SaveData.layerOne; no layerTwo class was found in dump.cs.
--   - This is a direct-state unlock script, not a “legit prestige simulation”.
--   - Running again is safe; values are simply overwritten.

openProcess('ScritchyScratchy.exe')
reinitializeSymbolhandler()

local MODULE_NAME = 'GameAssembly.dll'
local PROCESS_NAME = 'ScritchyScratchy.exe'

local SAVE_DATA_GET_CURRENT_RVA = 0x4D02F0
local PRESTIGE_MANAGER_GET_MAX_ACT_RVA = 0x4C90A0
local PERK_MANAGER_ACTIVATE_RVA = 0x4AE080
local SINGLETON_GET_CURRENT_RVA = 0xB812D0
local PERK_MANAGER_GET_CURRENT_CALLSITE_RVA = 0x4AE723

local SAVE_DATA_LAYERONE_OFFSET = 0x30
local SAVE_DATA_PRESTIGE_COUNT_OFFSET = 0x38
local SAVE_DATA_PRESTIGE_CURRENCY_OFFSET = 0x3C
local SAVE_DATA_CURRENT_ACT_OFFSET = 0x40
local SAVE_DATA_DEATH_COUNT_OFFSET = 0xBC
local SAVE_DATA_TOKENS_OFFSET = 0xC8

local LAYERONE_MONEY_OFFSET = 0x10
local LAYERONE_LAST_UNLOCKED_PROGRESSION_OFFSET = 0x50
local LAYERONE_SOULS_OFFSET = 0x88

local TARGET_LAYERONE_MONEY = 1.0e40
local TARGET_PRESTIGE_COUNT = 99
local TARGET_PRESTIGE_CURRENCY = 999999
local TARGET_DEATH_COUNT = 4
local TARGET_TOKENS = 999999999.0
local TARGET_LAST_UNLOCKED_PROGRESSION = 1.0e30
local TARGET_SOULS = 999999

local PERK_IDS = {
  0, 2, 3, 7, 8, 13, 15, 16, 18, 20, 21, 22, 23, 24, 25, 26,
  27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 40, 41, 42,
  43, 44, 45, 46, 47,
}

local function log(msg)
  print('[prestige_unlock] ' .. msg)
end

local function hex(v)
  if not v then
    return 'nil'
  end
  return string.format('0x%X', v)
end

local function ensureTarget()
  for _ = 1, 20 do
    pcall(function()
      openProcess(PROCESS_NAME)
    end)
    reinitializeSymbolhandler()
    local base = getAddressSafe(MODULE_NAME)
    if base and base ~= 0 then
      return base
    end
    sleep(250)
  end
  error(MODULE_NAME .. ' not found. Attach to ' .. PROCESS_NAME .. ' first.')
end

local function ensureStub(symbolName, nearSymbol, body)
  local existing = getAddressSafe(symbolName)
  if existing and existing ~= 0 then
    return existing
  end

  local script = string.format([[
alloc(%s,256,%s)
registersymbol(%s)
%s:
%s
]], symbolName, nearSymbol, symbolName, symbolName, body)

  local ok, err = autoAssemble(script)
  if not ok then
    error('autoAssemble failed for ' .. symbolName .. ': ' .. tostring(err))
  end

  return assert(getAddressSafe(symbolName), 'stub symbol missing: ' .. symbolName)
end

local function ensureSaveDataGetCurrentStub()
  return ensureStub(
    'ss_prestige_savedata_getcurrent_stub',
    MODULE_NAME .. '+4D02F0',
    [[
  sub rsp,40
  xor ecx,ecx
  call GameAssembly.dll+4D02F0
  add rsp,40
  ret
]]
  )
end

local function ensureGetMaxActStub()
  return ensureStub(
    'ss_prestige_getmaxact_stub',
    MODULE_NAME .. '+4C90A0',
    [[
  sub rsp,40
  xor ecx,ecx
  call GameAssembly.dll+4C90A0
  add rsp,40
  ret
]]
  )
end

local function ensureActivatePerkStub()
  return ensureStub(
    'ss_prestige_activateperk_stub',
    MODULE_NAME .. '+4AE080',
    [[
  sub rsp,40
  call GameAssembly.dll+4AE080
  add rsp,40
  ret
]]
  )
end

local function readMovRipTarget(instrAddr)
  local bytes = readBytes(instrAddr, 7, true)
  if not bytes or #bytes < 7 then
    return nil, nil, 'failed to read bytes at ' .. hex(instrAddr)
  end

  if bytes[1] ~= 0x48 or bytes[2] ~= 0x8B or bytes[3] ~= 0x0D then
    return nil, nil, 'unexpected RIP-relative mov at ' .. hex(instrAddr)
  end

  local disp = bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24)
  if disp >= 0x80000000 then
    disp = disp - 0x100000000
  end

  local slot = instrAddr + 7 + disp
  local value = readQword(slot)
  return value, slot, nil
end

local function getSingletonCurrentFromCallsite(callsiteRva)
  local base = ensureTarget()
  local genericCtx, ctxSlot, ctxErr = readMovRipTarget(base + callsiteRva)
  if ctxErr then
    return nil, nil, nil, ctxErr
  end

  if not genericCtx or genericCtx == 0 then
    return nil, nil, ctxSlot, 'generic context pointer is null'
  end

  local current = executeMethod(0, 5000, base + SINGLETON_GET_CURRENT_RVA, genericCtx)
  if not current or current == 0 then
    return nil, genericCtx, ctxSlot, 'SingletonMonoBehaviour<T>.get_Current() returned null'
  end

  return current, genericCtx, ctxSlot, nil
end

local function callNoThis(stubAddr)
  return executeCodeEx(0, 5000, stubAddr)
end

local function callActivatePerk(stubAddr, manager, perkId, count)
  return executeMethod(0, 5000, stubAddr, manager, {type = 0, value = perkId}, {type = 0, value = count})
end

local base = ensureTarget()
local getCurrentStub = ensureSaveDataGetCurrentStub()
local getMaxActStub = ensureGetMaxActStub()
local activatePerkStub = ensureActivatePerkStub()

local saveData = callNoThis(getCurrentStub)
if not saveData or saveData == 0 then
  error('SaveData.get_Current() returned null')
end

local layerOne = readQword(saveData + SAVE_DATA_LAYERONE_OFFSET)
if not layerOne or layerOne == 0 then
  error('SaveData.layerOne is null')
end

local maxAct = callNoThis(getMaxActStub)
if not maxAct or maxAct == 0 then
  maxAct = 5
end

writeInteger(saveData + SAVE_DATA_PRESTIGE_COUNT_OFFSET, TARGET_PRESTIGE_COUNT)
writeInteger(saveData + SAVE_DATA_PRESTIGE_CURRENCY_OFFSET, TARGET_PRESTIGE_CURRENCY)
writeInteger(saveData + SAVE_DATA_CURRENT_ACT_OFFSET, maxAct)
writeInteger(saveData + SAVE_DATA_DEATH_COUNT_OFFSET, TARGET_DEATH_COUNT)
writeDouble(saveData + SAVE_DATA_TOKENS_OFFSET, TARGET_TOKENS)

writeDouble(layerOne + LAYERONE_MONEY_OFFSET, TARGET_LAYERONE_MONEY)
writeDouble(layerOne + LAYERONE_LAST_UNLOCKED_PROGRESSION_OFFSET, TARGET_LAST_UNLOCKED_PROGRESSION)
writeInteger(layerOne + LAYERONE_SOULS_OFFSET, TARGET_SOULS)

local perkManager, perkGenericCtx, perkCtxSlot, perkErr = getSingletonCurrentFromCallsite(PERK_MANAGER_GET_CURRENT_CALLSITE_RVA)
local activated = 0
local failed = {}

if perkManager and perkManager ~= 0 then
  for _, perkId in ipairs(PERK_IDS) do
    local okCall, err = pcall(function()
      callActivatePerk(activatePerkStub, perkManager, perkId, 1)
    end)
    if okCall then
      activated = activated + 1
    else
      failed[#failed + 1] = string.format('%d:%s', perkId, tostring(err))
    end
  end
else
  failed[#failed + 1] = 'perk_manager_missing:' .. tostring(perkErr)
end

local summary = {
  string.format('base=%s', hex(base)),
  string.format('saveData=%s', hex(saveData)),
  string.format('layerOne=%s', hex(layerOne)),
  string.format('perkManager=%s', hex(perkManager)),
  string.format('perkGenericCtx=%s', hex(perkGenericCtx)),
  string.format('perkCtxSlot=%s', hex(perkCtxSlot)),
  string.format('maxAct=%s', tostring(readInteger(saveData + SAVE_DATA_CURRENT_ACT_OFFSET, 4))),
  string.format('prestigeCount=%s', tostring(readInteger(saveData + SAVE_DATA_PRESTIGE_COUNT_OFFSET, 4))),
  string.format('prestigeCurrency=%s', tostring(readInteger(saveData + SAVE_DATA_PRESTIGE_CURRENCY_OFFSET, 4))),
  string.format('deathCount=%s', tostring(readInteger(saveData + SAVE_DATA_DEATH_COUNT_OFFSET, 4))),
  string.format('tokens=%s', tostring(readDouble(saveData + SAVE_DATA_TOKENS_OFFSET))),
  string.format('layerOne.money=%s', tostring(readDouble(layerOne + LAYERONE_MONEY_OFFSET))),
  string.format('layerOne.souls=%s', tostring(readInteger(layerOne + LAYERONE_SOULS_OFFSET, 4))),
  string.format('layerOne.lastUnlockedProgressionGoal=%s', tostring(readDouble(layerOne + LAYERONE_LAST_UNLOCKED_PROGRESSION_OFFSET))),
  string.format('activatedPerks=%d/%d', activated, #PERK_IDS),
}

if #failed > 0 then
  summary[#summary + 1] = 'WARN failures=' .. table.concat(failed, ', ')
else
  summary[#summary + 1] = 'OK all perks activated'
end

local result = table.concat(summary, ' | ')
log(result)
return result
