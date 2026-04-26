-- custom_save_fields.lua - whitelisted runtime SaveData / LayerOne scalar writer
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function n(value, default)
  local parsed = tonumber(value)
  if parsed == nil or parsed ~= parsed or parsed == math.huge or parsed == -math.huge then return default end
  return parsed
end
local function shouldWrite(value)
  return value ~= nil and tostring(value) ~= ''
end
local function clamp(value, minv, maxv)
  if value < minv then return minv end
  if value > maxv then return maxv end
  return value
end

local function getSaveData()
  local cached = rawget(_G, 'SCRITCHY_CACHED_SAVEDATA')
  if cached and cached ~= 0 then
    local layer = readQword(cached + 0x30)
    if layer and layer ~= 0 then return cached, 'cache' end
    rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', nil)
  end

  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', 'SaveData')
  if cls then
    local saddr = rawget(_G, 'SCRITCHY_SAVEDATA_STATIC_ADDR') or mono_class_getStaticFieldAddress(0, cls)
    if saddr and saddr ~= 0 then
      rawset(_G, 'SCRITCHY_SAVEDATA_STATIC_ADDR', saddr)
      local currentOffset = rawget(_G, 'SCRITCHY_SAVEDATA_CURRENT_OFFSET')
      if not currentOffset then
        for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do
          if f.name == '_current' or f.name == 'current' then
            currentOffset = f.offset
            rawset(_G, 'SCRITCHY_SAVEDATA_CURRENT_OFFSET', currentOffset)
            break
          end
        end
      end
      if currentOffset then
        local p = readQword(saddr + currentOffset)
        if p and p ~= 0 then rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', p); return p, 'mono_static' end
      end
    end
  end

  local ok, ptr = pcall(function()
    return executeMethod(0, 750, base + 0x4D02F0, {type=0, value=0})
  end)
  if ok and ptr and ptr ~= 0 then
    rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', ptr)
    return ptr, 'method'
  end
  return nil, 'not_found'
end

local saveData, source = getSaveData()
if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end
local layerOne = readQword(saveData + 0x30)
if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData=' .. hx(saveData) end

local out = {string.format('custom save fields saveData=%s source=%s layerOne=%s', hx(saveData), tostring(source), hx(layerOne))}

local function writeIntField(label, addr, value, minv, maxv)
  if not shouldWrite(value) then return end
  local before = readInteger(addr, 4)
  local target = math.floor(n(value, before or 0))
  target = clamp(target, minv or 0, maxv or 2147483647)
  writeInteger(addr, target)
  local after = readInteger(addr, 4)
  out[#out+1] = string.format('%s %s -> %s', label, tostring(before), tostring(after))
end

local function writeDoubleField(label, addr, value, minv, maxv)
  if not shouldWrite(value) then return end
  local before = readDouble(addr)
  local target = n(value, before or 0)
  target = clamp(target, minv or 0, maxv or 1e300)
  writeDouble(addr, target)
  local after = readDouble(addr)
  out[#out+1] = string.format('%s %s -> %s', label, tostring(before), tostring(after))
end

writeDoubleField('money', saveData ~= 0 and layerOne + 0x10 or 0, SCRITCHY_CUSTOM_MONEY, 0, 1e300)
writeDoubleField('tokens', saveData + 0xC8, SCRITCHY_CUSTOM_TOKENS, 0, 1e300)
writeIntField('souls', layerOne + 0x88, SCRITCHY_CUSTOM_SOULS, 0, 2147483647)
writeIntField('prestigeCurrency', saveData + 0x3C, SCRITCHY_CUSTOM_PRESTIGE_CURRENCY, 0, 2147483647)
writeIntField('prestigeCount', saveData + 0x38, SCRITCHY_CUSTOM_PRESTIGE_COUNT, 0, 999999)
writeIntField('currentAct', saveData + 0x40, SCRITCHY_CUSTOM_ACT, 0, 99)

if #out == 1 then
  out[#out+1] = 'no fields selected'
end
return table.concat(out, '\n')
