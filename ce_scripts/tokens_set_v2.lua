-- tokens_set_v2.lua - no stubs, direct executeMethod
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local TARGET = 999999999.0

-- Try executeMethod directly (static method, hidden MethodInfo*=0 as last arg)
local savedata = nil
local ok, result = pcall(function()
  return executeMethod(0, 5000, base + 0x4D02F0, {type=0, value=0})
end)
if ok and result and result ~= 0 then
  savedata = result
end

-- Fallback: mono API
if not savedata or savedata == 0 then
  pcall(LaunchMonoDataCollector)
  local cls = pcall(mono_findClass, '', 'SaveData') and mono_findClass('', 'SaveData')
  if cls then
    local saddr = mono_class_getStaticFieldAddress(0, cls)
    if saddr and saddr ~= 0 then
      local fields = mono_class_enumFields(cls, true) or {}
      for _, f in ipairs(fields) do
        if f.name == '_current' or f.name == 'current' then
          savedata = readQword(saddr + f.offset)
          break
        end
      end
    end
  end
end

if not savedata or savedata == 0 then return 'ERR: SaveData instance nil' end

writeDouble(savedata + 0xC8, TARGET)
local allowSetTokensCall = (SCRITCHY_ALLOW_SETTOKENS_CALL == true)
if allowSetTokensCall then
  pcall(function()
    executeMethod(0, 5000, base + 0x4CFAA0, savedata, {type=2, value=TARGET}, {type=0, value=0})
  end)
end

local v = readDouble(savedata + 0xC8)
return string.format('OK savedata=0x%X tokens=%.0f setTokensCall=%s', savedata, v or -1, tostring(allowSetTokensCall))

