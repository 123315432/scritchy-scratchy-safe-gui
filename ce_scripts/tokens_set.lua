-- tokens_set.lua
-- Usage:
--   1. Attach Cheat Engine to ScritchyScratchy.exe
--   2. Run this Lua script once
-- Behavior:
--   - Calls SaveData.get_Current()
--   - Writes SaveData.tokens directly to 999999999.0 at +0xC8
--   - Calls SaveData.SetTokens(999999999.0) to refresh UI / dependent state
-- Notes:
--   dump.cs shows SetTokens uses double.
--   IL2CPP hidden MethodInfo* is passed as 0 on direct calls.

local GAME_EXE = 'ScritchyScratchy.exe'
local MODULE_NAME = 'GameAssembly.dll'
local TARGET_TOKENS = 999999999.0

local SAVE_DATA_GET_CURRENT_RVA = 0x4D02F0
local SAVE_DATA_SET_TOKENS_RVA = 0x4CFAA0
local SAVE_DATA_TOKENS_OFFSET = 0xC8

local function log(msg)
  print('[tokens_set] ' .. msg)
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

local function tryInitIl2Cpp()
  if type(LaunchMonoDataCollector) ~= 'function' then
    return false, 'LaunchMonoDataCollector is unavailable'
  end

  for _ = 1, 3 do
    local ok = LaunchMonoDataCollector()
    if ok ~= 0 then
      if type(mono_isil2cpp) ~= 'function' or mono_isil2cpp() then
        return true, 'LaunchMonoDataCollector succeeded'
      end
    end

    local cls = mono_findClass('', 'SaveData')
    if cls then
      return true, 'mono class lookup succeeded'
    end

    sleep(250)
  end

  return false, 'LaunchMonoDataCollector failed'
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

local function ensureGetCurrentStub()
  return ensureStub(
    'ss_tokens_getcurrent_stub',
    MODULE_NAME .. '+4D02F0',
    [[
  sub rsp,40
  xor ecx,ecx
  call GameAssembly.dll+4D02F0
  add rsp,40
  ret
]]
  )
end

local function ensureSetTokensStub()
  return ensureStub(
    'ss_tokens_set_stub',
    MODULE_NAME .. '+4CFAA0',
    [[
  sub rsp,40
  call GameAssembly.dll+4CFAA0
  add rsp,40
  ret
]]
  )
end

local function getCurrentSaveData()
  local stub, err = ensureGetCurrentStub()
  if stub then
    local ok, result = pcall(function()
      return executeCodeEx(0, 5000, stub)
    end)
    if ok and result and result ~= 0 then
      return result, 'SaveData.get_Current()', stub
    end
  end

  local monoReady = tryInitIl2Cpp()
  if monoReady then
    local current = readStaticObjectField('SaveData', '_current')
    if current and current ~= 0 then
      return current, 'SaveData._current static field', nil
    end
  end

  return nil, err or 'SaveData instance not found', nil
end

local base, err = ensureTarget()
if not base then
  log('ERROR: ' .. err)
  return
end

local saveData, saveVia, getCurrentStub = getCurrentSaveData()
if not saveData or saveData == 0 then
  log('ERROR: ' .. tostring(saveVia))
  return
end

writeDouble(saveData + SAVE_DATA_TOKENS_OFFSET, TARGET_TOKENS)

local setStub, setStubErr = ensureSetTokensStub()
if not setStub then
  log('ERROR: failed to build SetTokens stub: ' .. tostring(setStubErr))
  return
end

local okCall, callErr = pcall(function()
  executeMethod(0, 5000, setStub, saveData, {type = 2, value = TARGET_TOKENS}, {type = 0, value = 0})
end)

local current = readDouble(saveData + SAVE_DATA_TOKENS_OFFSET)
if okCall then
  log(string.format('OK: save=%s tokens=%s via=%s getCurrentStub=%s setTokensStub=%s', hex(saveData), tostring(current), tostring(saveVia), hex(getCurrentStub), hex(setStub)))
else
  log(string.format('WARN: direct write worked but SetTokens call failed: %s', tostring(callErr)))
  log(string.format('WARN: save=%s tokens=%s via=%s getCurrentStub=%s setTokensStub=%s', hex(saveData), tostring(current), tostring(saveVia), hex(getCurrentStub), hex(setStub)))
end
