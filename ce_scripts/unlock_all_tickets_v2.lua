-- unlock_all_tickets_v2.lua - direct executeMethod, no stubs, no reinitializeSymbolhandler
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local function hex(v) return v and string.format('0x%X', v) or 'nil' end

-- Get SaveData via executeMethod directly
local savedata = nil
local ok, result = pcall(function()
  return executeMethod(0, 5000, base + 0x4D02F0, {type=0, value=0})
end)
if ok and result and result ~= 0 then savedata = result end

-- Fallback: mono
if not savedata or savedata == 0 then
  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', 'SaveData')
  if cls then
    local saddr = mono_class_getStaticFieldAddress(0, cls)
    if saddr and saddr ~= 0 then
      local fields = mono_class_enumFields(cls, true) or {}
      for _, f in ipairs(fields) do
        if f.name == '_current' or f.name == 'current' then
          savedata = readQword(saddr + f.offset)
          break
        end
      end
    end
  end
end

if not savedata or savedata == 0 then return 'ERR: SaveData nil' end

-- Set max act
writeInteger(savedata + 0x40, 5)  -- currentAct

-- Push layerOne progression gate
local layerOne = readQword(savedata + 0x30)
if layerOne and layerOne ~= 0 then
  writeDouble(layerOne + 0x50, 1.0e30)  -- lastUnlockedProgressionGoal
end

-- Try DebugTools.UnlockAllTickets() via callsite RIP-relative
local DEBUGTOOLS_GET_CURRENT_CALLSITE_RVA = 0x49361D
local SINGLETON_GETCURRENT_RVA = 0xB812D0
local UNLOCK_ALL_TICKETS_RVA = 0x493660
local SKIP_TO_ACT_RVA = 0x4924C0

local debugTools = nil
local unlockCalled = false
local allowDebugToolsCalls = (SCRITCHY_ALLOW_DEBUGTOOLS_CALLS == true)

local callsiteAddr = base + DEBUGTOOLS_GET_CURRENT_CALLSITE_RVA
local instrBytes = readBytes(callsiteAddr, 7, true)
if instrBytes and #instrBytes >= 7 and instrBytes[1] == 0x48 and instrBytes[2] == 0x8B and instrBytes[3] == 0x0D then
  local disp = instrBytes[4] | (instrBytes[5] << 8) | (instrBytes[6] << 16) | (instrBytes[7] << 24)
  if disp >= 0x80000000 then disp = disp - 0x100000000 end
  local slot = callsiteAddr + 7 + disp
  local genericCtx = readQword(slot)
  if genericCtx and genericCtx ~= 0 then
    local dt_ok, dt_result = pcall(function()
      return executeMethod(0, 5000, base + SINGLETON_GETCURRENT_RVA, genericCtx)
    end)
    if dt_ok and dt_result and dt_result ~= 0 then debugTools = dt_result end
  end
end

if debugTools and debugTools ~= 0 and allowDebugToolsCalls then
  -- Call UnlockAllTickets(debugTools)
  local call_ok = pcall(function()
    executeMethod(0, 5000, base + UNLOCK_ALL_TICKETS_RVA, debugTools, {type=0, value=0})
  end)
  unlockCalled = call_ok

  -- Call SkipToAct(maxAct)
  pcall(function()
    executeMethod(0, 5000, base + SKIP_TO_ACT_RVA, debugTools, {type=1, value=5}, {type=0, value=0})
  end)
end

local actNow = readInteger(savedata + 0x40, 4)
return string.format('OK savedata=%s layerOne=%s debugTools=%s unlockCalled=%s actNow=%s debugToolsCalls=%s',
  hex(savedata), hex(layerOne), hex(debugTools), tostring(unlockCalled), tostring(actNow), tostring(allowDebugToolsCalls))



