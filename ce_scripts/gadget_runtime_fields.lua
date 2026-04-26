-- gadget_runtime_fields.lua - whitelisted runtime helper gadget field reader-writer
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local MODE = tostring(SCRITCHY_GADGET_MODE or 'status')
local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function clamp(v, lo, hi)
  v = tonumber(v)
  if not v then return nil end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
local function wanted(value) return value ~= nil and tostring(value) ~= '' end

local function findInstance(className)
  local cached = rawget(_G, 'SCRITCHY_CACHED_' .. className)
  if cached and cached ~= 0 then
    local ok = pcall(function() readQword(cached) end)
    if ok then return cached, 'cache' end
    rawset(_G, 'SCRITCHY_CACHED_' .. className, nil)
  end
  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', className)
  if not cls then return nil, 'class_not_found_' .. className end
  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}
  if list[1] and list[1] ~= 0 then
    rawset(_G, 'SCRITCHY_CACHED_' .. className, list[1])
    return list[1], 'mono_instance'
  end
  return nil, 'instance_not_found_' .. className
end

local out = {string.format('gadget runtime mode=%s', MODE)}
local instances = {}
local sources = {}
local touched = 0

local function instanceFor(className)
  if instances[className] ~= nil then return instances[className], sources[className] end
  local ptr, source = findInstance(className)
  instances[className] = ptr or false
  sources[className] = source
  return ptr, source
end

local function fieldFloat(className, label, offset, value, lo, hi)
  local ptr, source = instanceFor(className)
  if not ptr or ptr == 0 then
    out[#out+1] = string.format('%s.%s=not_found source=%s', className, label, tostring(source))
    return
  end
  local before = readFloat(ptr + offset)
  if MODE == 'apply' and wanted(value) then
    local target = clamp(value, lo, hi)
    if target then writeFloat(ptr + offset, target); touched = touched + 1 end
  end
  local after = readFloat(ptr + offset)
  out[#out+1] = string.format('%s.%s=%s -> %s ptr=%s source=%s', className, label, tostring(before), tostring(after), hx(ptr), tostring(source))
end

local function fieldInt(className, label, offset, value, lo, hi)
  local ptr, source = instanceFor(className)
  if not ptr or ptr == 0 then
    out[#out+1] = string.format('%s.%s=not_found source=%s', className, label, tostring(source))
    return
  end
  local before = readInteger(ptr + offset)
  if MODE == 'apply' and wanted(value) then
    local target = clamp(value, lo, hi)
    if target then writeInteger(ptr + offset, math.floor(target)); touched = touched + 1 end
  end
  local after = readInteger(ptr + offset)
  out[#out+1] = string.format('%s.%s=%s -> %s ptr=%s source=%s', className, label, tostring(before), tostring(after), hx(ptr), tostring(source))
end

fieldFloat('EggTimer', 'BatteryCapacityMult', 0x40, SCRITCHY_EGGTIMER_BATTERY_CAPACITY_MULT, 0.01, 100000)
fieldFloat('EggTimer', 'BatteryChargeMult', 0x44, SCRITCHY_EGGTIMER_BATTERY_CHARGE_MULT, 0.01, 100000)
fieldFloat('EggTimer', 'MultMultiplier', 0x48, SCRITCHY_EGGTIMER_MULT_MULTIPLIER, 0.01, 100000)
fieldFloat('Fan', 'BatteryCapacityMult', 0x68, SCRITCHY_FAN_BATTERY_CAPACITY_MULT, 0.01, 100000)
fieldFloat('Fan', 'BatteryChargeMult', 0x6C, SCRITCHY_FAN_BATTERY_CHARGE_MULT, 0.01, 100000)
fieldFloat('Fan', 'SpeedMult', 0x70, SCRITCHY_FAN_SPEED_MULT, 0.01, 100000)
fieldFloat('Mundo', 'ClaimSpeedMult', 0xB8, SCRITCHY_MUNDO_CLAIM_SPEED_MULT, 0.01, 100000)
fieldInt('ScratchBot', 'capacity', 0xC4, SCRITCHY_SCRATCHBOT_CAPACITY, 0, 100000)
fieldInt('ScratchBot', 'strength', 0xC8, SCRITCHY_SCRATCHBOT_STRENGTH, 0, 100000)
fieldFloat('ScratchBot', 'speedMult', 0xCC, SCRITCHY_SCRATCHBOT_SPEED_MULT, 0.01, 100000)
fieldFloat('ScratchBot', 'extraSpeed', 0xD0, SCRITCHY_SCRATCHBOT_EXTRA_SPEED, 0.0, 100000)
fieldFloat('ScratchBot', 'extraCapacity', 0xD4, SCRITCHY_SCRATCHBOT_EXTRA_CAPACITY, 0.0, 100000)
fieldInt('ScratchBot', 'extraStrength', 0xD8, SCRITCHY_SCRATCHBOT_EXTRA_STRENGTH, 0, 100000)
fieldFloat('SpellBook', 'RechargeSpeedMult', 0x28, SCRITCHY_SPELLBOOK_RECHARGE_SPEED_MULT, 0.01, 100000)

out[#out+1] = string.format('OK touchedFields=%d', touched)
return table.concat(out, '\n')
