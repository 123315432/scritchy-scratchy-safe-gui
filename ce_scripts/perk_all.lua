-- perk_all.lua
-- Usage:
--   1. Attach Cheat Engine to ScritchyScratchy.exe
--   2. Run this Lua script once
-- Behavior:
--   - Activates perk IDs 1..50 at level/count 1
--   - HandsOff (19) and FullyAutomated (36) are activated first and retried at the end
--   - Expect auto / semi-auto scratching related behavior to become available immediately
-- Notes:
--   IL2CPP hidden MethodInfo* is passed as 0 on direct calls.

local GAME_EXE = 'ScritchyScratchy.exe'
local MODULE_NAME = 'GameAssembly.dll'
local PERK_MANAGER_ACTIVATE_RVA = 0x4AE080

local IMPORTANT_PERKS = {
  19, -- HandsOff
  36, -- FullyAutomated
}

local function log(msg)
  print('[perk_all] ' .. msg)
end

local function hex(v)
  if not v then
    return 'nil'
  end
  return string.format('0x%X', v)
end

local function ensureTarget()
  pcall(openProcess, GAME_EXE)
  local base = getAddressSafe(MODULE_NAME)
  if not base or base == 0 then
    return nil, MODULE_NAME .. ' is not loaded. Attach to ' .. GAME_EXE .. ' first.'
  end
  return base
end

local function ensureIl2Cpp()
  if type(LaunchMonoDataCollector) ~= 'function' then
    return nil, 'LaunchMonoDataCollector is unavailable'
  end

  for _ = 1, 3 do
    local ok = LaunchMonoDataCollector()
    if ok ~= 0 then
      if type(mono_isil2cpp) ~= 'function' or mono_isil2cpp() then
        return true, 'LaunchMonoDataCollector succeeded'
      end
    end

    local cls = mono_findClass('', 'PerkManager')
    if cls then
      return true, 'mono class lookup succeeded'
    end

    sleep(250)
  end

  return nil, 'LaunchMonoDataCollector failed'
end

local function findClass(className)
  return mono_findClass('', className)
end

local function findField(classHandle, fieldName)
  if not classHandle then
    return nil
  end

  local fields = mono_class_enumFields(classHandle, true) or {}
  for _, field in ipairs(fields) do
    if field.name == fieldName then
      return field
    end
  end

  return nil
end

local function readStaticObjectField(className, fieldName)
  local classHandle = findClass(className)
  if not classHandle then
    return nil, className .. ' class not found'
  end

  local field = findField(classHandle, fieldName)
  if not field then
    return nil, className .. '.' .. fieldName .. ' not found'
  end

  local staticData = mono_class_getStaticFieldAddress(0, classHandle)
  if not staticData or staticData == 0 then
    return nil, className .. ' static storage is missing'
  end

  local value = readQword(staticData + field.offset)
  if not value or value == 0 then
    return nil, className .. '.' .. fieldName .. ' is null'
  end

  return value
end

local function findFirstInstance(className)
  local classHandle = findClass(className)
  if not classHandle then
    return nil
  end

  local list = mono_class_findInstancesOfClassListOnly(nil, classHandle) or {}
  for _, instance in ipairs(list) do
    if instance and instance ~= 0 then
      return instance
    end
  end

  return nil
end

local function findPerkManager()
  local current = readStaticObjectField('PerkManager', '_current')
  if current and current ~= 0 then
    return current, 'PerkManager._current'
  end

  local instance = findFirstInstance('PerkManager')
  if instance and instance ~= 0 then
    return instance, 'PerkManager instance scan'
  end

  return nil, 'PerkManager instance not found'
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
    return nil, err
  end

  return getAddressSafe(symbolName)
end

local function ensureActivateStub()
  return ensureStub(
    'ss_perk_activate_stub',
    MODULE_NAME .. '+4AE080',
    [[
  sub rsp,40
  call GameAssembly.dll+4AE080
  add rsp,40
  ret
]]
  )
end

local function activatePerk(stubAddr, manager, perkId, count)
  executeMethod(0, 5000, stubAddr, manager, {type = 0, value = perkId}, {type = 0, value = count}, {type = 0, value = 0})
end

local base, err = ensureTarget()
if not base then
  log('ERROR: ' .. err)
  return
end

local okIl2Cpp, il2cppErr = ensureIl2Cpp()
if not okIl2Cpp then
  log('ERROR: ' .. il2cppErr)
  return
end

local manager, managerVia = findPerkManager()
if not manager or manager == 0 then
  log('ERROR: ' .. tostring(managerVia))
  return
end

local activateStub, stubErr = ensureActivateStub()
if not activateStub then
  log('ERROR: failed to build ActivatePerk stub: ' .. tostring(stubErr))
  return
end

local targets = {}
for _, perkId in ipairs(IMPORTANT_PERKS) do
  targets[#targets + 1] = perkId
end
for perkId = 1, 50 do
  if perkId ~= 19 and perkId ~= 36 then
    targets[#targets + 1] = perkId
  end
end
for _, perkId in ipairs(IMPORTANT_PERKS) do
  targets[#targets + 1] = perkId
end

local successCount = 0
local failed = {}

for _, perkId in ipairs(targets) do
  local okCall, callErr = pcall(function()
    activatePerk(activateStub, manager, perkId, 1)
  end)
  if okCall then
    successCount = successCount + 1
  else
    failed[#failed + 1] = string.format('%d:%s', perkId, tostring(callErr))
  end
end

if #failed == 0 then
  log(string.format('OK: activated %d perk calls via manager=%s (%s), stub=%s', successCount, hex(manager), managerVia, hex(activateStub)))
else
  log(string.format('WARN: activated %d perk calls, %d failed via manager=%s (%s)', successCount, #failed, hex(manager), managerVia))
  log('WARN: failures=' .. table.concat(failed, ', '))
end
