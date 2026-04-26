-- subscription_bot_runtime.lua - safe runtime SubscriptionBot field reader/writer
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local MODE = tostring(SCRITCHY_SUB_RUNTIME_MODE or 'status')
if MODE ~= 'status' and MODE ~= 'apply' then return 'ERR: SCRITCHY_SUB_RUNTIME_MODE must be status/apply, got=' .. MODE end
local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function clamp(v, lo, hi)
  v = tonumber(v)
  if not v then return nil end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
local function wanted(value) return value ~= nil and tostring(value) ~= '' end
local function boolValue(v)
  if v == true or v == 1 or v == '1' then return 1 end
  if v == false or v == 0 or v == '0' then return 0 end
  local s = tostring(v):lower()
  if s == 'true' or s == 'yes' or s == 'on' then return 1 end
  if s == 'false' or s == 'no' or s == 'off' then return 0 end
  return nil
end
local function rstr(p)
  if p and p ~= 0 and p < 0x0000800000000000 then return readString(p + 0x14, 256, true) end
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

local bot, source = findInstance('SubscriptionBot')
if not bot or bot == 0 then return 'ERR: SubscriptionBot nil source=' .. tostring(source) end

local out = {string.format('subscription runtime bot=%s source=%s mode=%s', hx(bot), tostring(source), MODE)}
local durationBefore = readFloat(bot + 0x28)
local maxBefore = readInteger(bot + 0x48, 4)
local currentTicket = readQword(bot + 0x50)
local pausedBefore = readBytes(bot + 0x58, 1, false)
local elapsed = readFloat(bot + 0x5C)
local speedBefore = readFloat(bot + 0x60)
if MODE == 'apply' and wanted(SCRITCHY_SUB_PROCESSING_DURATION) then
  local target = clamp(SCRITCHY_SUB_PROCESSING_DURATION, 0.01, 3600)
  if target then writeFloat(bot + 0x28, target) end
end
if MODE == 'apply' and wanted(SCRITCHY_SUB_MAX_TICKET_COUNT) then
  local target = clamp(SCRITCHY_SUB_MAX_TICKET_COUNT, 0, 100000)
  if target then writeInteger(bot + 0x48, math.floor(target)) end
end
if MODE == 'apply' and wanted(SCRITCHY_SUB_PAUSED) then
  local target = boolValue(SCRITCHY_SUB_PAUSED)
  if target ~= nil then writeBytes(bot + 0x58, target) end
end
if MODE == 'apply' and wanted(SCRITCHY_SUB_PROCESSING_SPEED_MULT) then
  local target = clamp(SCRITCHY_SUB_PROCESSING_SPEED_MULT, 0.01, 100000)
  if target then writeFloat(bot + 0x60, target) end
end
local durationAfter = readFloat(bot + 0x28)
local maxAfter = readInteger(bot + 0x48, 4)
local pausedAfter = readBytes(bot + 0x58, 1, false)
local speedAfter = readFloat(bot + 0x60)
local ticketId = nil
if currentTicket and currentTicket ~= 0 then
  ticketId = rstr(readQword(currentTicket + 0x10)) or rstr(readQword(currentTicket + 0x18))
end
out[#out+1] = string.format('processingDuration=%s -> %s', tostring(durationBefore), tostring(durationAfter))
out[#out+1] = string.format('maxTicketCount=%s -> %s', tostring(maxBefore), tostring(maxAfter))
out[#out+1] = string.format('paused=%s -> %s elapsedTime=%s', tostring(pausedBefore == 1), tostring(pausedAfter == 1), tostring(elapsed))
out[#out+1] = string.format('currentTicket=%s id=%s', hx(currentTicket), tostring(ticketId))
out[#out+1] = string.format('ProcessingSpeedMult=%s -> %s', tostring(speedBefore), tostring(speedAfter))
return table.concat(out, '\n')
