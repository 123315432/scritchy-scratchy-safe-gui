-- experimental_runtime_fields.lua - whitelisted experimental runtime reader-writer
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local MODE = tostring(SCRITCHY_EXPERIMENTAL_MODE or 'status')
if MODE ~= 'status' and MODE ~= 'apply' then return 'ERR: SCRITCHY_EXPERIMENTAL_MODE must be status/apply, got=' .. MODE end

local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function wanted(value) return value ~= nil and tostring(value) ~= '' end
local function clamp(v, lo, hi)
  v = tonumber(v)
  if not v then return nil end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
local function boolValue(v)
  if v == true or v == 1 or v == '1' then return 1 end
  if v == false or v == 0 or v == '0' then return 0 end
  local s = tostring(v):lower()
  if s == 'true' or s == 'yes' or s == 'on' then return 1 end
  if s == 'false' or s == 'no' or s == 'off' then return 0 end
  return nil
end

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

local out = {string.format('experimental runtime mode=%s', MODE)}
local touched = 0

local function fieldFloat(className, label, offset, value, lo, hi)
  local ptr, source = findInstance(className)
  if not ptr or ptr == 0 then
    out[#out+1] = string.format('%s.%s=not_found source=%s', className, label, tostring(source))
    return
  end
  local before = readFloat(ptr + offset)
  if MODE == 'apply' and wanted(value) then
    local target = clamp(value, lo, hi)
    if target ~= nil then writeFloat(ptr + offset, target); touched = touched + 1 end
  end
  local after = readFloat(ptr + offset)
  out[#out+1] = string.format('%s.%s=%s -> %s ptr=%s source=%s', className, label, tostring(before), tostring(after), hx(ptr), tostring(source))
end

local function fieldBool(className, label, offset, value)
  local ptr, source = findInstance(className)
  if not ptr or ptr == 0 then
    out[#out+1] = string.format('%s.%s=not_found source=%s', className, label, tostring(source))
    return
  end
  local before = readBytes(ptr + offset, 1, false)
  if MODE == 'apply' and wanted(value) then
    local target = boolValue(value)
    if target ~= nil then writeBytes(ptr + offset, target); touched = touched + 1 end
  end
  local after = readBytes(ptr + offset, 1, false)
  out[#out+1] = string.format('%s.%s=%s -> %s ptr=%s source=%s', className, label, tostring(before == 1), tostring(after == 1), hx(ptr), tostring(source))
end

fieldFloat('ScratchBot', 'processingDuration', 0x48, SCRITCHY_SCRATCHBOT_PROCESSING_DURATION, 0.01, 3600)
fieldBool('Mundo', 'paused', 0xBC, SCRITCHY_MUNDO_PAUSED)

out[#out+1] = string.format('OK touchedFields=%d', touched)
return table.concat(out, '\n')
