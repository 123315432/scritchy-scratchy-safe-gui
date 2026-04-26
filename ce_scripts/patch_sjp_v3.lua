-- SJP Patch v3: restore je (prevent Phase 2 recursion) + high weight
-- Strategy: let jackpotsGotten filter naturally (Phase 2 SJP ticket won't be in list)
-- Float write path intentionally uses fullAccess + writeFloat to satisfy the task requirement.
openProcess('ScritchyScratchy.exe')

local base = getAddress('GameAssembly.dll')
if not base or base == 0 then
  return 'ERR: GameAssembly.dll not found'
end

local r = 'base=0x'..string.format('%X',base)

local function bytesToHex(bytes)
  if not bytes then
    return 'READ_FAIL'
  end

  local parts = {}
  for i = 1, #bytes do
    parts[#parts + 1] = string.format('%02X', bytes[i])
  end
  return table.concat(parts, ' ')
end

local function readBytesSafe(addr, count)
  return readBytes(addr, count, true)
end

local function readIl2CppString(obj)
  if not obj or obj == 0 then
    return nil
  end

  local len = readInteger(obj + 0x10)
  if not len or len < 0 or len > 512 then
    return string.format('<badlen:%s>', tostring(len))
  end

  return readString(obj + 0x14, len * 2, true)
end

local function findField(classHandle, fieldName)
  if not classHandle then
    return nil
  end

  local fields = mono_class_enumFields(classHandle, true)
  for _, field in ipairs(fields) do
    if field.name == fieldName then
      return field
    end
  end

  return nil
end

local function dumpJackpotsGotten()
  if type(LaunchMonoDataCollector) ~= 'function' then
    return 'mono_api_missing'
  end

  LaunchMonoDataCollector()
  if not mono_isil2cpp() then
    return 'mono_not_il2cpp'
  end

  local saveClass = mono_findClass('', 'SaveData')
  local layerOneClass = mono_findClass('', 'PrestigeLayerOneData')
  if not saveClass or not layerOneClass then
    return 'class_lookup_failed'
  end

  local currentField = findField(saveClass, '_current')
  local layerOneField = findField(saveClass, 'layerOne')
  local jackpotsField = findField(layerOneClass, 'jackpotsGotten')
  if not currentField or not layerOneField or not jackpotsField then
    return 'field_lookup_failed'
  end

  local staticData = mono_class_getStaticFieldAddress(0, saveClass)
  if not staticData or staticData == 0 then
    return 'static_data_missing'
  end

  local current = readQword(staticData + currentField.offset)
  if not current or current == 0 then
    return string.format('current=0x%X', current or 0)
  end

  local layerOne = readQword(current + layerOneField.offset)
  if not layerOne or layerOne == 0 then
    return string.format('current=0x%X layerOne=0x%X', current, layerOne or 0)
  end

  local jackpotsList = readQword(layerOne + jackpotsField.offset)
  if not jackpotsList or jackpotsList == 0 then
    return string.format('current=0x%X layerOne=0x%X jackpots=0x%X', current, layerOne, jackpotsList or 0)
  end

  local items = readQword(jackpotsList + 0x10)
  local size = readInteger(jackpotsList + 0x18) or -1
  local capacity = (items and items ~= 0) and (readInteger(items + 0x18) or -1) or -1
  local luckyCat = false
  local entries = {}

  if items and items ~= 0 and size >= 0 and size < 256 then
    for i = 0, size - 1 do
      local strObj = readQword(items + 0x20 + i * 8)
      local text = readIl2CppString(strObj) or '<null>'
      if text == 'Lucky Cat' then
        luckyCat = true
      end
      entries[#entries + 1] = text
    end
  end

  return string.format(
    'current=0x%X layerOne=0x%X jackpots=0x%X items=0x%X size=%d cap=%d luckyCat=%s entries=[%s]',
    current,
    layerOne,
    jackpotsList,
    items or 0,
    size,
    capacity,
    tostring(luckyCat),
    table.concat(entries, '|')
  )
end

-- Patch 1: RESTORE original je at RVA 0x4B09EF (undo the nop)
-- Original bytes: 0F 84 61 01 00 00 (je +0x161)
local p1 = base + 0x4B09EF
local cur = readBytesSafe(p1, 6)
if cur and cur[1] == 0x90 then
  writeBytes(p1, 0x0F, 0x84, 0x61, 0x01, 0x00, 0x00)
  r = r..' P1=JE_RESTORED'
elseif cur and cur[1] == 0x0F then
  r = r..' P1=already_je'
else
  r = r..' P1=UNEXPECTED_'..bytesToHex(cur)
end
r = r..' P1_BYTES='..bytesToHex(readBytesSafe(p1, 6))

-- Patch 2: write 99999.0 to the chance constant using writeFloat
local p2 = base + 0x29FCCD0
local p2FullAccessOk = true
if type(fullAccess) == 'function' then
  local okAccess = pcall(function()
    fullAccess(p2, 4)
  end)
  p2FullAccessOk = okAccess
end

local okWrite, errWrite = pcall(function()
  writeFloat(p2, 99999.0)
end)

local p2Value = readFloat(p2)
if okWrite and p2Value and math.abs(p2Value - 99999.0) < 0.01 then
  r = r..' P2=WRITEFLOAT_OK access='..tostring(p2FullAccessOk)..' val='..p2Value
else
  r = r..' P2=WRITEFLOAT_FAIL access='..tostring(p2FullAccessOk)..' err='..tostring(errWrite)..' val='..tostring(p2Value)
end

r = r..' | DIAG='..dumpJackpotsGotten()

return r
