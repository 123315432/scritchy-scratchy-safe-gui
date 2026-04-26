-- helper_state_fields.lua - safe LayerOne helper state rescue reader-writer
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local MODE = tostring(SCRITCHY_HELPER_STATE_MODE or 'status')
if MODE ~= 'status' and MODE ~= 'apply' then return 'ERR: SCRITCHY_HELPER_STATE_MODE must be status/apply, got=' .. MODE end

local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function wanted(v) return v ~= nil and tostring(v) ~= '' end
local function boolValue(v)
  if v == true or v == 1 or v == '1' then return 1 end
  if v == false or v == 0 or v == '0' then return 0 end
  local s = tostring(v):lower()
  if s == 'true' or s == 'yes' or s == 'on' then return 1 end
  if s == 'false' or s == 'no' or s == 'off' then return 0 end
  return nil
end
local function clampFloat(v, lo, hi)
  v = tonumber(v)
  if not v then return nil end
  if v < lo then v = lo end
  if v > hi then v = hi end
  return v
end
local function getSaveData()
  local cached = rawget(_G, 'SCRITCHY_CACHED_SAVEDATA')
  if cached and cached ~= 0 then
    local layer = readQword(cached + 0x30)
    if layer and layer ~= 0 then return cached, 'cache' end
    rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', nil)
  end
  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', 'SaveData')
  if cls then
    local saddr = rawget(_G, 'SCRITCHY_SAVEDATA_STATIC_ADDR') or mono_class_getStaticFieldAddress(0, cls)
    if saddr and saddr ~= 0 then
      rawset(_G, 'SCRITCHY_SAVEDATA_STATIC_ADDR', saddr)
      local currentOffset = rawget(_G, 'SCRITCHY_SAVEDATA_CURRENT_OFFSET')
      if not currentOffset then
        for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do
          if f.name == '_current' or f.name == 'current' then
            currentOffset = f.offset
            rawset(_G, 'SCRITCHY_SAVEDATA_CURRENT_OFFSET', currentOffset)
            break
          end
        end
      end
      if currentOffset then
        local p = readQword(saddr + currentOffset)
        if p and p ~= 0 then
          rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', p)
          return p, 'mono_static'
        end
      end
    end
  end
  return nil, 'not_found'
end

local saveData, source = getSaveData()
if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end
local layerOne = readQword(saveData + 0x30)
if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData=' .. hx(saveData) end

local out = {string.format('helper state saveData=%s source=%s layerOne=%s mode=%s', hx(saveData), tostring(source), hx(layerOne), MODE)}

local function fieldFloat(label, offset, value)
  local before = readFloat(layerOne + offset)
  if MODE == 'apply' and wanted(value) then
    local target = clampFloat(value, 0, 100000)
    if target ~= nil then writeFloat(layerOne + offset, target) end
  end
  local after = readFloat(layerOne + offset)
  out[#out+1] = string.format('%s=%s -> %s', label, tostring(before), tostring(after))
end

local function fieldBool(label, offset, value)
  local before = readBytes(layerOne + offset, 1, false)
  if MODE == 'apply' and wanted(value) then
    local target = boolValue(value)
    if target ~= nil then writeBytes(layerOne + offset, target) end
  end
  local after = readBytes(layerOne + offset, 1, false)
  out[#out+1] = string.format('%s=%s -> %s', label, tostring(before == 1), tostring(after == 1))
end

fieldFloat('electricFanChargeLeft', 0x98, SCRITCHY_ELECTRIC_FAN_CHARGE_LEFT)
fieldBool('fanPaused', 0x9C, SCRITCHY_FAN_PAUSED)
fieldFloat('eggTimerChargeLeft', 0xA0, SCRITCHY_EGG_TIMER_CHARGE_LEFT)
fieldBool('mundoDead', 0xA4, SCRITCHY_MUNDO_DEAD)
fieldBool('trashCanDead', 0xA5, SCRITCHY_TRASH_CAN_DEAD)
return table.concat(out, '\n')
