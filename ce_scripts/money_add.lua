-- money_add.lua
-- Usage:
--   1. Attach Cheat Engine to ScritchyScratchy.exe
--   2. Run this Lua script once
-- Behavior:
--   - Preferred path: call PlayerWallet.AddMoney(999999.0, "cheat")
--   - Fallback 1: call PlayerWallet.SetMoney(999999.0)
--   - Fallback 2: write SaveData.tokens directly and call SaveData.SetTokens for UI refresh
-- Notes:
--   dump.cs shows AddMoney/SetMoney use double, not float.
--   IL2CPP hidden MethodInfo* is passed as 0 on direct calls.

local GAME_EXE = 'ScritchyScratchy.exe'
local MODULE_NAME = 'GameAssembly.dll'
local TARGET_MONEY = 999999.0
local TARGET_TOKENS = 999999.0

local PLAYER_WALLET_ADD_MONEY_RVA = 0x4C2580
local PLAYER_WALLET_SET_MONEY_RVA = 0x4C2B80
local SAVE_DATA_GET_CURRENT_RVA = 0x4D02F0
local SAVE_DATA_SET_TOKENS_RVA = 0x4CFAA0

local PLAYER_WALLET_FIELD_OFFSET_IN_PLAYER = 0xA0
local SAVE_DATA_TOKENS_OFFSET = 0xC8

local function log(msg)
  print('[money_add] ' .. msg)
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

    local cls = mono_findClass('', 'PlayerWallet')
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

local function findPlayerWallet()
  local wallet = findFirstInstance('PlayerWallet')
  if wallet and wallet ~= 0 then
    return wallet, 'PlayerWallet instance scan'
  end

  local player = readStaticObjectField('Player', '_current')
  if player and player ~= 0 then
    local playerWallet = readQword(player + PLAYER_WALLET_FIELD_OFFSET_IN_PLAYER)
    if playerWallet and playerWallet ~= 0 then
      return playerWallet, 'Player._current + 0xA0'
    end
  end

  local playerInstance = findFirstInstance('Player')
  if playerInstance and playerInstance ~= 0 then
    local playerWallet = readQword(playerInstance + PLAYER_WALLET_FIELD_OFFSET_IN_PLAYER)
    if playerWallet and playerWallet ~= 0 then
      return playerWallet, 'Player instance + 0xA0'
    end
  end

  return nil, 'PlayerWallet instance not found'
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
    'ss_savedata_getcurrent_stub',
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

local function ensureAddMoneyStub()
  return ensureStub(
    'ss_money_add_stub',
    MODULE_NAME .. '+4C2580',
    [[
  sub rsp,40
  call GameAssembly.dll+4C2580
  add rsp,40
  ret
]]
  )
end

local function resolveExport(exportName)
  local addr = getAddressSafe(MODULE_NAME .. '!' .. exportName)
  if addr and addr ~= 0 then
    return addr
  end

  addr = getAddressSafe(exportName)
  if addr and addr ~= 0 then
    return addr
  end

  return nil
end

local function createManagedString(text)
  local stringNew = resolveExport('il2cpp_string_new')
  if not stringNew then
    return nil, 'il2cpp_string_new export not found'
  end

  local ok, result = pcall(function()
    return executeCodeEx(0, 5000, stringNew, {type = 3, value = text})
  end)
  if not ok or not result or result == 0 then
    return nil, 'il2cpp_string_new call failed'
  end

  return result
end

local function getCurrentSaveData()
  local stub, err = ensureGetCurrentStub()
  if not stub then
    local current = readStaticObjectField('SaveData', '_current')
    if current and current ~= 0 then
      return current, 'SaveData._current static field'
    end
    return nil, err or 'SaveData.get_Current stub unavailable'
  end

  local ok, result = pcall(function()
    return executeCodeEx(0, 5000, stub)
  end)
  if ok and result and result ~= 0 then
    return result, 'SaveData.get_Current()'
  end

  local current = readStaticObjectField('SaveData', '_current')
  if current and current ~= 0 then
    return current, 'SaveData._current static field'
  end

  return nil, 'SaveData current instance not found'
end

local function callSetMoney(base, wallet, value)
  local ok, err = pcall(function()
    executeMethod(0, 5000, base + PLAYER_WALLET_SET_MONEY_RVA, wallet, {type = 2, value = value}, {type = 0, value = 0})
  end)
  return ok, err
end

local function fallbackWriteTokens(base, value)
  local saveData, via = getCurrentSaveData()
  if not saveData or saveData == 0 then
    return nil, 'SaveData instance not found'
  end

  writeDouble(saveData + SAVE_DATA_TOKENS_OFFSET, value)

  pcall(function()
    executeMethod(0, 5000, base + SAVE_DATA_SET_TOKENS_RVA, saveData, {type = 2, value = value}, {type = 0, value = 0})
  end)

  return saveData, via
end

local base, err = ensureTarget()
if not base then
  log('ERROR: ' .. err)
  return
end

local monoReady, monoMsg = tryInitIl2Cpp()
if not monoReady then
  log('WARN: mono path unavailable, using non-mono fallbacks where possible: ' .. tostring(monoMsg))
end

local wallet, walletVia = nil, nil
if monoReady then
  wallet, walletVia = findPlayerWallet()
end

if wallet and wallet ~= 0 then
  local addStub, addErr = ensureAddMoneyStub()
  if addStub then
    local sourcePtr, sourceErr = createManagedString('cheat')
    if sourcePtr and sourcePtr ~= 0 then
      local okCall, callErr = pcall(function()
        executeMethod(0, 5000, addStub, wallet, {type = 2, value = TARGET_MONEY}, {type = 0, value = sourcePtr}, {type = 0, value = 0})
      end)
      if okCall then
        log(string.format('OK: AddMoney invoked via stub=%s wallet=%s source=%s (%s)', hex(addStub), hex(wallet), hex(sourcePtr), walletVia))
        return
      end
      log('WARN: AddMoney call failed: ' .. tostring(callErr))
    else
      log('WARN: managed string creation unavailable: ' .. tostring(sourceErr))
    end
  else
    log('WARN: AddMoney stub build failed: ' .. tostring(addErr))
  end

  local setOk, setErr = callSetMoney(base, wallet, TARGET_MONEY)
  if setOk then
    log(string.format('OK: SetMoney fallback used wallet=%s (%s)', hex(wallet), walletVia))
    return
  end
  log('WARN: SetMoney fallback failed: ' .. tostring(setErr))
else
  log('WARN: PlayerWallet lookup failed: ' .. tostring(walletVia))
end

local saveData, saveVia = fallbackWriteTokens(base, TARGET_TOKENS)
if saveData and saveData ~= 0 then
  local current = readDouble(saveData + SAVE_DATA_TOKENS_OFFSET)
  log(string.format('OK: SaveData.tokens fallback used save=%s currentTokens=%s (%s)', hex(saveData), tostring(current), tostring(saveVia)))
  return
end

log('ERROR: unable to resolve PlayerWallet or SaveData fallback path')
