-- Maximize Super Jackpot chance with data writes only (no code patch).
-- Usage:
--   1) Run while ScritchyScratchy.exe is open.
--   2) Optional override before execution: SJP_CHANCE_VALUE = 99999.0
-- Notes:
--   - Writes the primary TryGetSJP float constant at GameAssembly.dll+0x29FCCD0.
--   - Re-derives the same constant through an AOB hit on the TryGetSJP movss site for validation.
--   - Tries to boost live SymbolChance objects of SymbolType.SuperJackpot (type=3) when present.
--   - When no live SymbolChance table exists yet, the constant write still takes effect for the next generation path.

openProcess('ScritchyScratchy.exe')

local MODULE_NAME = 'GameAssembly.dll'
local CHANCE_CONST_RVA = 0x29FCCD0
local MOVSS_SIG = 'F3 0F 10 35 ?? ?? ?? ?? 4C 8D 84 24 98 00 00 00'
local DEFAULT_VALUE = 99999.0
local TARGET_SYMBOL_TYPE = 3

local function writeFloatChecked(addr, value)
  if type(fullAccess) == 'function' then
    pcall(function()
      fullAccess(addr, 4)
    end)
  end

  local okWrite, errWrite = pcall(function()
    writeFloat(addr, value)
  end)
  local verify = readFloat(addr)

  return okWrite, errWrite, verify
end

local function parseRipRelativeTarget(hit)
  if not hit or hit == 0 then
    return nil
  end

  local disp = readInteger(hit + 4)
  if disp == nil then
    return nil
  end

  return hit + 8 + disp
end

local function findField(classHandle, fieldName)
  local fields = mono_class_enumFields(classHandle, true) or {}
  for _, field in ipairs(fields) do
    if field.name == fieldName then
      return field
    end
  end
end

local function tryBoostLiveSymbolChance(value)
  if type(LaunchMonoDataCollector) ~= 'function' then
    return 0, 'mono_api_missing'
  end

  LaunchMonoDataCollector()
  if not mono_isil2cpp() then
    return 0, 'mono_not_il2cpp'
  end

  local symbolChanceClass = mono_findClass('', 'SymbolChance')
  local symbolDataClass = mono_findClass('', 'SymbolData')
  if not symbolChanceClass or symbolChanceClass == 0 or not symbolDataClass or symbolDataClass == 0 then
    return 0, 'symbolchance_class_missing'
  end

  local objects = mono_class_findInstancesOfClassListOnly(symbolChanceClass) or {}
  local boosted = 0

  for _, obj in ipairs(objects) do
    local data = readQword(obj + 0x10) or 0
    if data ~= 0 and mono_object_getClass(obj) == symbolChanceClass and mono_object_getClass(data) == symbolDataClass then
      local symbolType = readInteger(data + 0x38)
      if symbolType == TARGET_SYMBOL_TYPE then
        local _, _, verify = writeFloatChecked(obj + 0x18, value)
        if verify and math.abs(verify - value) < 0.01 then
          boosted = boosted + 1
        end
      end
    end
  end

  if boosted > 0 then
    return boosted, 'live_symbolchance_objects'
  end

  local perkClass = mono_findClass('', 'PerkManager')
  if not perkClass or perkClass == 0 then
    return 0, 'perkmanager_class_missing'
  end

  local parent = mono_class_getParent(perkClass)
  if not parent or parent == 0 then
    return 0, 'perkmanager_parent_missing'
  end

  local currentField = findField(parent, '_current')
  local symbolsField = findField(perkClass, 'symbols')
  if not currentField or not symbolsField then
    return 0, 'perkmanager_field_missing'
  end

  local staticData = mono_class_getStaticFieldAddress(0, parent)
  if not staticData or staticData == 0 then
    return 0, 'perkmanager_static_missing'
  end

  local perkManager = readQword(staticData + currentField.offset) or 0
  if perkManager == 0 then
    return 0, 'perkmanager_current_null'
  end

  local list = readQword(perkManager + symbolsField.offset) or 0
  if list == 0 then
    return 0, 'perkmanager_symbols_null'
  end

  local items = readQword(list + 0x10) or 0
  local size = readInteger(list + 0x18) or 0
  if items == 0 or size <= 0 or size > 512 then
    return 0, string.format('perkmanager_symbols_size_%d', size)
  end

  for i = 0, size - 1 do
    local obj = readQword(items + 0x20 + i * 8) or 0
    if obj ~= 0 and mono_object_getClass(obj) == symbolChanceClass then
      local data = readQword(obj + 0x10) or 0
      local symbolType = data ~= 0 and mono_object_getClass(data) == symbolDataClass and readInteger(data + 0x38) or nil
      if symbolType == TARGET_SYMBOL_TYPE then
        local _, _, verify = writeFloatChecked(obj + 0x18, value)
        if verify and math.abs(verify - value) < 0.01 then
          boosted = boosted + 1
        end
      end
    end
  end

  return boosted, 'perkmanager_symbols_list'
end

local base = getAddress(MODULE_NAME)
if not base or base == 0 then
  return 'ERR: GameAssembly.dll not loaded'
end

local targetValue = tonumber(rawget(_G, 'SJP_CHANCE_VALUE')) or DEFAULT_VALUE

local directAddr = base + CHANCE_CONST_RVA
local directOk, directErr, directVerify = writeFloatChecked(directAddr, targetValue)

local aobHit = AOBScanUnique(MOVSS_SIG)
local aobAddr = parseRipRelativeTarget(aobHit)
local aobOk = false
local aobErr = nil
local aobVerify = nil

if aobAddr and aobAddr ~= directAddr then
  aobOk, aobErr, aobVerify = writeFloatChecked(aobAddr, targetValue)
elseif aobAddr == directAddr then
  aobOk = true
  aobVerify = readFloat(aobAddr)
else
  aobErr = 'aob_not_found'
end

local boostedCount, boostedSource = tryBoostLiveSymbolChance(targetValue)

return string.format(
  'base=0x%X targetValue=%s directAddr=0x%X directOk=%s directErr=%s directVerify=%s aobHit=%s aobAddr=%s aobOk=%s aobErr=%s aobVerify=%s boosted=%d boostedSource=%s',
  base,
  tostring(targetValue),
  directAddr,
  tostring(directOk),
  tostring(directErr),
  tostring(directVerify),
  tostring(aobHit),
  tostring(aobAddr),
  tostring(aobOk),
  tostring(aobErr),
  tostring(aobVerify),
  boostedCount,
  tostring(boostedSource)
)
