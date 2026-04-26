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

-- Perk activation intentionally skipped in no_perks variant to avoid native-call crash risk
local perkMgr = nil
local perkActivated = 0

local tokensNow = readDouble(savedata + 0xC8)
local prestigeNow = readInteger(savedata + 0x38, 4)
return string.format('OK savedata=%s layerOne=%s perkMgr=%s tokens=%.0f prestige=%d perksActivated=%d',
  hex(savedata), hex(layerOne), hex(perkMgr), tokensNow or -1, prestigeNow or -1, perkActivated)

