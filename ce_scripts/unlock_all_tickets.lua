-- unlock_all_tickets.lua
-- Usage:
--   1. Attach Cheat Engine to ScritchyScratchy.exe
--   2. Run this Lua script once
-- Behavior:
--   - Resolves SaveData.get_Current()
--   - Forces currentAct to max
--   - Pushes layerOne progression gate to final ticket threshold
--   - Calls DebugTools.UnlockAllTickets() if DebugTools singleton exists
-- Notes:
--   - This uses the game's own debug-side unlock path plus persistent-state writes.
--   - Current build did not expose a separate layerTwo save root.

openProcess('ScritchyScratchy.exe')
reinitializeSymbolhandler()

local MODULE_NAME = 'GameAssembly.dll'
local PROCESS_NAME = 'ScritchyScratchy.exe'

local SAVE_DATA_GET_CURRENT_RVA = 0x4D02F0
local DEBUGTOOLS_UNLOCK_ALL_TICKETS_RVA = 0x493660
local DEBUGTOOLS_SKIP_TO_ACT_RVA = 0x4924C0
local PRESTIGE_MANAGER_GET_MAX_ACT_RVA = 0x4C90A0
local SINGLETON_GET_CURRENT_RVA = 0xB812D0
local DEBUGTOOLS_GET_CURRENT_CALLSITE_RVA = 0x49361D

local SAVE_DATA_LAYERONE_OFFSET = 0x30
local SAVE_DATA_CURRENT_ACT_OFFSET = 0x40

local LAYERONE_LAST_UNLOCKED_PROGRESSION_OFFSET = 0x50
local TARGET_LAST_UNLOCKED_PROGRESSION = 1.0e30

local function log(msg)
  print('[unlock_all_tickets] ' .. msg)
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
    'ss_unlock_savedata_getcurrent_stub',
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

local function ensureUnlockAllTicketsStub()
  return ensureStub(
    'ss_unlock_debugtools_unlockall_stub',
    MODULE_NAME .. '+493660',
    [[
  sub rsp,40
  call GameAssembly.dll+493660
  add rsp,40
  ret
]]
  )
end

local function ensureGetMaxActStub()
  return ensureStub(
    'ss_unlock_getmaxact_stub',
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

local function callNoThis(stubAddr)
  return executeCodeEx(0, 5000, stubAddr)
end

local function callUnlockAll(stubAddr, debugTools)
  return executeMethod(0, 5000, stubAddr, debugTools)
end

local function callSkipToAct(debugTools, act)
  local base = ensureTarget()
  return executeMethod(0, 5000, base + DEBUGTOOLS_SKIP_TO_ACT_RVA, debugTools, {type = 0, value = act})
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

local base = ensureTarget()
local getCurrentStub = ensureSaveDataGetCurrentStub()
local unlockStub = ensureUnlockAllTicketsStub()
local getMaxActStub = ensureGetMaxActStub()

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

writeInteger(saveData + SAVE_DATA_CURRENT_ACT_OFFSET, maxAct)
writeDouble(layerOne + LAYERONE_LAST_UNLOCKED_PROGRESSION_OFFSET, TARGET_LAST_UNLOCKED_PROGRESSION)

local debugTools, debugGenericCtx, debugCtxSlot, debugErr = getSingletonCurrentFromCallsite(DEBUGTOOLS_GET_CURRENT_CALLSITE_RVA)
local unlockOk = false
local unlockErr = nil
local skipOk = false
local skipErr = nil

if debugTools and debugTools ~= 0 then
  skipOk, skipErr = pcall(function()
    callSkipToAct(debugTools, maxAct)
  end)
  unlockOk, unlockErr = pcall(function()
    callUnlockAll(unlockStub, debugTools)
  end)
else
  unlockErr = 'DebugTools singleton missing: ' .. tostring(debugErr)
end

local summary = {
  string.format('base=%s', hex(base)),
  string.format('saveData=%s', hex(saveData)),
  string.format('layerOne=%s', hex(layerOne)),
  string.format('debugTools=%s', hex(debugTools)),
  string.format('debugGenericCtx=%s', hex(debugGenericCtx)),
  string.format('debugCtxSlot=%s', hex(debugCtxSlot)),
  string.format('currentAct=%s', tostring(readInteger(saveData + SAVE_DATA_CURRENT_ACT_OFFSET, 4))),
  string.format('layerOne.lastUnlockedProgressionGoal=%s', tostring(readDouble(layerOne + LAYERONE_LAST_UNLOCKED_PROGRESSION_OFFSET))),
  string.format('skipToAct=%s', tostring(skipOk)),
  string.format('unlockCall=%s', tostring(unlockOk)),
}

if skipErr then
  summary[#summary + 1] = 'WARN skip=' .. tostring(skipErr)
end

if unlockErr then
  summary[#summary + 1] = 'WARN unlock=' .. tostring(unlockErr)
else
  summary[#summary + 1] = 'OK DebugTools.UnlockAllTickets called'
end

local result = table.concat(summary, ' | ')
log(result)
return result
