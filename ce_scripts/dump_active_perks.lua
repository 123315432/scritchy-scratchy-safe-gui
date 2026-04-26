-- dump_active_perks.lua - read-only activePerks dictionary resolver
openProcess('ScritchyScratchy.exe')
pcall(LaunchMonoDataCollector)
local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function safeString(sp)
  if sp and sp ~= 0 and sp < 0x0000800000000000 then
    return readString(sp + 0x14, 128, true)
  end
  return nil
end
local cls = mono_findClass('', 'PerkManager')
if not cls then return 'ERR: PerkManager class not found' end
local managers = mono_class_findInstancesOfClassListOnly(nil, cls) or {}
local manager = managers[1]
if not manager or manager == 0 then return 'ERR: PerkManager instance not found' end
local dict = readQword(manager + 0x28)
if not dict or dict == 0 then return 'ERR: activePerks nil manager=' .. hx(manager) end
local entries = readQword(dict + 0x18)
if not entries or entries == 0 then return 'ERR: entries nil dict=' .. hx(dict) end
local count = readInteger(dict + 0x20, 4)
local version = readInteger(dict + 0x24, 4)
local arrlen = readInteger(entries + 0x18, 4)
local out = {}
out[#out+1] = string.format('PerkManager=%s activePerks=%s entries=%s count=%s version=%s capacity=%s', hx(manager), hx(dict), hx(entries), tostring(count), tostring(version), tostring(arrlen))
out[#out+1] = 'type\tentry\tkey\ttuple\titem2\tperkData\tperkId\tperkType\tperkCount\tperkValue'
local valid = 0
for i=0,(arrlen or 0)-1 do
  local entry = entries + 0x20 + i * 0x18
  local hash = readInteger(entry, 4)
  local key = readInteger(entry + 0x08, 4)
  local tuple = readQword(entry + 0x10)
  if hash and hash >= 0 and tuple and tuple ~= 0 and tuple < 0x0000800000000000 then
    local perkData = readQword(tuple + 0x10)
    local item2 = readInteger(tuple + 0x18, 4)
    local perkId, perkType, perkCount, perkValue = nil, nil, nil, nil
    if perkData and perkData ~= 0 and perkData < 0x0000800000000000 then
      perkId = safeString(readQword(perkData + 0x10))
      perkType = readInteger(perkData + 0x18, 4)
      perkCount = readInteger(perkData + 0x30, 4)
      perkValue = readFloat(perkData + 0x34)
    end
    valid = valid + 1
    out[#out+1] = string.format('%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s', tostring(hash), i, key or -1, hx(tuple), tostring(item2), hx(perkData), tostring(perkId), tostring(perkType), tostring(perkCount), tostring(perkValue))
  end
end
out[#out+1] = 'valid=' .. tostring(valid)
return table.concat(out, '\n')
