-- scratch_runtime_fields.lua - whitelisted runtime PlayerScratching / ScratchTool field reader-writer
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local MODE = tostring(SCRITCHY_SCRATCH_MODE or 'status')
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
  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', className)
  if not cls then return nil, 'class_not_found_' .. className end
  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}
  if list[1] and list[1] ~= 0 then return list[1], 'mono_instance' end
  return nil, 'instance_not_found_' .. className
end

local scratching, source = findInstance('PlayerScratching')
if not scratching or scratching == 0 then return 'ERR: PlayerScratching nil source=' .. tostring(source) end
local tool = readQword(scratching + 0x28)

local out = {string.format('scratch runtime scratching=%s source=%s tool=%s mode=%s', hx(scratching), tostring(source), hx(tool), MODE)}

local function fieldFloat(label, addr, value, lo, hi)
  local before = readFloat(addr)
  if MODE == 'apply' and wanted(value) then
    local target = clamp(value, lo, hi)
    if target then writeFloat(addr, target) end
  end
  local after = readFloat(addr)
  out[#out+1] = string.format('%s=%s -> %s', label, tostring(before), tostring(after))
end

local function fieldInt(label, addr, value, lo, hi)
  local before = readInteger(addr, 4)
  if MODE == 'apply' and wanted(value) then
    local target = clamp(value, lo, hi)
    if target then writeInteger(addr, math.floor(target)) end
  end
  local after = readInteger(addr, 4)
  out[#out+1] = string.format('%s=%s -> %s', label, tostring(before), tostring(after))
end

fieldFloat('scratchParticleSpeed', scratching + 0x3C, SCRITCHY_SCRATCH_PARTICLE_SPEED, 0.1, 10000)
fieldFloat('mouseVelocityMax', scratching + 0x48, SCRITCHY_MOUSE_VELOCITY_MAX, 0.1, 100000)
fieldInt('scratchChecksPerSecond', scratching + 0x4C, SCRITCHY_SCRATCH_CHECKS_PER_SECOND, 1, 240)
fieldInt('scratchLuck', scratching + 0x94, SCRITCHY_SCRATCH_LUCK, -100000, 100000)
fieldInt('luckReduction', scratching + 0x98, SCRITCHY_LUCK_REDUCTION, -100000, 100000)
if tool and tool ~= 0 then
  fieldInt('toolStrength', tool + 0x28, SCRITCHY_TOOL_STRENGTH, 0, 100000)
  fieldInt('toolSizeBacking', tool + 0x30, SCRITCHY_TOOL_SIZE, 0, 100000)
  fieldInt('toolSizeReduction', tool + 0x34, SCRITCHY_TOOL_SIZE_REDUCTION, -100000, 100000)
else
  out[#out+1] = 'tool=nil skipped tool fields'
end
return table.concat(out, '\n')
