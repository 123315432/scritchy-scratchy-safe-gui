-- Directly trigger Super Jackpot via SuperJackpotManager.TriggerSuperJackpot(string).
-- Usage:
--   1) Keep ScritchyScratchy.exe running and make sure a ticket/gameplay context is active.
--   2) Optional override before execution: SJP_TRIGGER_ID = 'Lucky Cat'
--   3) Optional dry run before execution: SJP_DRY_RUN = true
-- Notes:
--   - Resolves SuperJackpotManager through SingletonMonoBehaviour<T>._current on the generic parent.
--   - Builds a managed System.String with mono_new_string.
--   - Calls GameAssembly.dll+0x4B5930 through an autoAssemble thread stub.

openProcess('ScritchyScratchy.exe')

local MODULE_NAME = 'GameAssembly.dll'
local TRIGGER_RVA = 0x4B5930
local DEFAULT_TRIGGER_ID = 'Lucky Cat'

local function readIl2CppString(obj)
  if not obj or obj == 0 then
    return nil
  end

  local len = readInteger(obj + 0x10)
  if not len or len < 0 or len > 256 then
    return string.format('<badlen:%s>', tostring(len))
  end

  return readString(obj + 0x14, len * 2, true)
end

local function findField(classHandle, fieldName)
  local fields = mono_class_enumFields(classHandle, true) or {}
  for _, field in ipairs(fields) do
    if field.name == fieldName then
      return field
    end
  end
end

local function resolveSingletonCurrent(className)
  local classHandle = mono_findClass('', className)
  if not classHandle or classHandle == 0 then
    return nil, 'class_lookup_failed'
  end

  local parent = mono_class_getParent(classHandle)
  if not parent or parent == 0 then
    return nil, 'parent_lookup_failed'
  end

  local currentField = findField(parent, '_current')
  if not currentField then
    return nil, 'current_field_missing'
  end

  local staticData = mono_class_getStaticFieldAddress(0, parent)
  if not staticData or staticData == 0 then
    return nil, 'static_data_missing'
  end

  local current = readQword(staticData + currentField.offset)
  if not current or current == 0 then
    return nil, 'current_null'
  end

  return current
end

local function getManagerTriggerId(manager)
  local overrideId = rawget(_G, 'SJP_TRIGGER_ID')
  if type(overrideId) == 'string' and overrideId ~= '' then
    return overrideId, 'override'
  end

  local originalTicketIdObj = readQword(manager + 0x98)
  local originalTicketId = readIl2CppString(originalTicketIdObj)
  if originalTicketId and originalTicketId ~= '' and not originalTicketId:match('^<badlen:') then
    return originalTicketId, 'manager.originalTicketID'
  end

  return DEFAULT_TRIGGER_ID, 'default'
end

local function buildCallScript(tag, manager, idObj, fn)
  return string.format([[
alloc(%s,0x1000,GameAssembly.dll)
%s:
  sub rsp,28
  mov rcx,%X
  mov rdx,%X
  xor r8,r8
  mov rax,%X
  call rax
  add rsp,28
  ret
createthread(%s)
]], tag, tag, manager, idObj, fn, tag)
end

local base = getAddress(MODULE_NAME)
if not base or base == 0 then
  return 'ERR: GameAssembly.dll not loaded'
end

if type(LaunchMonoDataCollector) ~= 'function' then
  return 'ERR: LaunchMonoDataCollector missing'
end

LaunchMonoDataCollector()
if not mono_isil2cpp() then
  return 'ERR: IL2CPP collector unavailable in the current CE session; re-attach Mono/IL2CPP features and rerun'
end

if type(mono_new_string) ~= 'function' then
  return 'ERR: mono_new_string missing'
end

local manager, resolveErr = resolveSingletonCurrent('SuperJackpotManager')
if not manager then
  return 'ERR: resolve SuperJackpotManager failed: '..tostring(resolveErr)
end

local triggerId, triggerSource = getManagerTriggerId(manager)
local idObj = mono_new_string(triggerId)
if not idObj or idObj == 0 then
  return 'ERR: mono_new_string failed for '..triggerId
end

local fn = base + TRIGGER_RVA
local preActive = readBytes(manager + 0xC8, 1, true)[1] or 0
local preOriginalTicket = readQword(manager + 0x90) or 0
local preSuperTicket = readQword(manager + 0xC0) or 0

if rawget(_G, 'SJP_DRY_RUN') then
  return string.format(
    'DRY_RUN base=0x%X manager=0x%X fn=0x%X triggerId=%s source=%s idObj=0x%X preActive=%d preOriginal=0x%X preSuper=0x%X',
    base,
    manager,
    fn,
    triggerId,
    triggerSource,
    idObj,
    preActive,
    preOriginalTicket,
    preSuperTicket
  )
end

local tag = string.format('sjp_trigger_%X', getTickCount and getTickCount() or 0x51504A)
local okAA, errAA = autoAssemble(buildCallScript(tag, manager, idObj, fn))
sleep(400)

local postActive = readBytes(manager + 0xC8, 1, true)[1] or 0
local postOriginalTicket = readQword(manager + 0x90) or 0
local postSuperTicket = readQword(manager + 0xC0) or 0

pcall(function()
  autoAssemble(string.format('dealloc(%s)', tag))
end)

return string.format(
  'base=0x%X manager=0x%X fn=0x%X triggerId=%s source=%s idObj=0x%X AA=%s err=%s preActive=%d postActive=%d preOriginal=0x%X postOriginal=0x%X preSuper=0x%X postSuper=0x%X',
  base,
  manager,
  fn,
  triggerId,
  triggerSource,
  idObj,
  tostring(okAA),
  tostring(errAA),
  preActive,
  postActive,
  preOriginalTicket,
  postOriginalTicket,
  preSuperTicket,
  postSuperTicket
)
