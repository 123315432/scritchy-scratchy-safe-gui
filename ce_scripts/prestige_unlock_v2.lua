-- prestige_unlock_v2.lua - direct executeMethod, no stubs, no reinitializeSymbolhandler
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

-- Fallback: mono API
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

local layerOne = readQword(savedata + 0x30)
if not layerOne or layerOne == 0 then return 'ERR: layerOne nil at savedata=' .. hex(savedata) end

-- Write prestige fields to SaveData
writeInteger(savedata + 0x38, 99)           -- prestigeCount
writeInteger(savedata + 0x3C, 999999)       -- prestigeCurrency
writeInteger(savedata + 0x40, 5)            -- currentAct (max)
writeInteger(savedata + 0xBC, 4)            -- deathCount
writeDouble(savedata + 0xC8, 999999999.0)   -- tokens

-- Write layerOne fields
writeDouble(layerOne + 0x10, 1.0e40)        -- money
writeDouble(layerOne + 0x50, 1.0e30)        -- lastUnlockedProgressionGoal
writeInteger(layerOne + 0x88, 999999)       -- souls

-- Try PerkManager via callsite RIP-relative read
local PERK_CALLSITE_RVA = 0x4AE723
local SINGLETON_GETCURRENT_RVA = 0xB812D0
local ACTIVATE_PERK_RVA = 0x4AE080

local perkMgr = nil
local perkActivated = 0
local allowUnsafeActivatePerk = (SCRITCHY_ALLOW_UNSAFE_ACTIVATEPERK == true)

-- Read PerkManager genericCtx from callsite
local callsiteAddr = base + PERK_CALLSITE_RVA
local instrBytes = readBytes(callsiteAddr, 7, true)
if instrBytes and #instrBytes >= 7 and instrBytes[1] == 0x48 and instrBytes[2] == 0x8B and instrBytes[3] == 0x0D then
  local disp = instrBytes[4] | (instrBytes[5] << 8) | (instrBytes[6] << 16) | (instrBytes[7] << 24)
  if disp >= 0x80000000 then disp = disp - 0x100000000 end
  local slot = callsiteAddr + 7 + disp
  local genericCtx = readQword(slot)
  if genericCtx and genericCtx ~= 0 then
    local mgr_ok, mgr_result = pcall(function()
      return executeMethod(0, 5000, base + SINGLETON_GETCURRENT_RVA, genericCtx)
    end)
    if mgr_ok and mgr_result and mgr_result ~= 0 then perkMgr = mgr_result end
  end
end

-- Fallback: mono instance scan
if not perkMgr or perkMgr == 0 then
  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', 'PerkManager')
  if cls then
    local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}
    perkMgr = list[1]
  end
end

if perkMgr and perkMgr ~= 0 and allowUnsafeActivatePerk then
  local PERK_IDS = {0, 2, 3, 7, 8, 13, 15, 16, 18, 19, 20, 21, 22, 23, 24, 25,
    26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 40, 41, 42, 43, 44, 45, 46, 47}
  for _, pid in ipairs(PERK_IDS) do
    if pcall(function()
      executeMethod(0, 2000, base + ACTIVATE_PERK_RVA, perkMgr, {type=1, value=pid}, {type=1, value=1}, {type=0, value=0})
    end) then perkActivated = perkActivated + 1 end
  end
end

local tokensNow = readDouble(savedata + 0xC8)
local prestigeNow = readInteger(savedata + 0x38, 4)
return string.format('OK savedata=%s layerOne=%s perkMgr=%s tokens=%.0f prestige=%d perksActivated=%d unsafeActivatePerk=%s',
  hex(savedata), hex(layerOne), hex(perkMgr), tokensNow or -1, prestigeNow or -1, perkActivated, tostring(allowUnsafeActivatePerk))

