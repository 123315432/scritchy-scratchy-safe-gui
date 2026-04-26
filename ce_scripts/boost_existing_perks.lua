-- boost_existing_perks.lua - safe live update for existing perk entries only
-- Does not add dictionary entries, does not call ActivatePerk.
-- Updates activePerks Tuple<PerkData,int>, PerkData.count, and existing SaveData.boughtPrestigeUpgrades entries.
openProcess('ScritchyScratchy.exe')
pcall(LaunchMonoDataCollector)

local TARGET = tonumber(SCRITCHY_PERK_TARGET_COUNT or 10) or 10
local DRYRUN = (SCRITCHY_PERK_BOOST_DRYRUN ~= false)
local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function safeString(sp)
  if sp and sp ~= 0 and sp < 0x0000800000000000 then return readString(sp + 0x14, 128, true) end
  return nil
end

local function getSaveData()
  local cls = mono_findClass('', 'SaveData')
  if not cls then return nil end
  local saddr = mono_class_getStaticFieldAddress(0, cls)
  for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do
    if f.name == '_current' or f.name == 'current' then
      local p = readQword(saddr + f.offset)
      if p and p ~= 0 then return p end
    end
  end
  return nil
end

local function indexBoughtPrestigeUpgrades(saveData)
  local index = {}
  if not saveData or saveData == 0 then return index, 'no_savedata' end
  local dict = readQword(saveData + 0x60)
  local entries = dict and readQword(dict + 0x18) or nil
  if not entries or entries == 0 then return index, 'no_entries' end
  local arrlen = readInteger(entries + 0x18, 4) or 0
  for i=0,arrlen-1 do
    local entry = entries + 0x20 + i * 0x18
    local hash = readInteger(entry, 4)
    local keyPtr = readQword(entry + 0x08)
    local name = safeString(keyPtr)
    if hash and hash >= 0 and name and name ~= '' then
      index[name] = {entry=entry, value=readInteger(entry + 0x10, 4) or 0}
    end
  end
  return index, string.format('dict=%s entries=%s arrlen=%d', hx(dict), hx(entries), arrlen)
end

local cls = mono_findClass('', 'PerkManager')
if not cls then return 'ERR: PerkManager class not found' end
local manager = (mono_class_findInstancesOfClassListOnly(nil, cls) or {})[1]
if not manager or manager == 0 then return 'ERR: PerkManager instance not found' end
local dict = readQword(manager + 0x28)
local entries = dict and readQword(dict + 0x18) or nil
if not entries or entries == 0 then return 'ERR: activePerks entries not found manager=' .. hx(manager) .. ' dict=' .. hx(dict) end

local saveData = getSaveData()
local saveIndex, saveInfo = indexBoughtPrestigeUpgrades(saveData)
local arrlen = readInteger(entries + 0x18, 4)
local changed, seen, saveChanged, saveMissing = 0, 0, 0, 0
local out = {string.format('manager=%s dict=%s entries=%s saveData=%s saveInfo=%s target=%d dryrun=%s', hx(manager), hx(dict), hx(entries), hx(saveData), tostring(saveInfo), TARGET, tostring(DRYRUN))}
for i=0,(arrlen or 0)-1 do
  local entry = entries + 0x20 + i * 0x18
  local hash = readInteger(entry, 4)
  local key = readInteger(entry + 0x08, 4)
  local tuple = readQword(entry + 0x10)
  if hash and hash >= 0 and tuple and tuple ~= 0 and tuple < 0x0000800000000000 then
    seen = seen + 1
    local perkData = readQword(tuple + 0x10)
    local item2 = readInteger(tuple + 0x18, 4) or 0
    local id, ptype, pcount = nil, nil, nil
    if perkData and perkData ~= 0 and perkData < 0x0000800000000000 then
      id = safeString(readQword(perkData + 0x10))
      ptype = readInteger(perkData + 0x18, 4)
      pcount = readInteger(perkData + 0x30, 4) or 0
    end
    local saveEntry = id and saveIndex[id] or nil
    local saveCount = saveEntry and saveEntry.value or nil
    local newCount = math.max(item2, pcount or 0, saveCount or 0, TARGET)
    if newCount ~= item2 or (pcount and newCount ~= pcount) then
      changed = changed + 1
      out[#out+1] = string.format('boost %s type=%s entry=%d tupleItem2 %s->%s perkCount %s->%s', tostring(id), tostring(ptype or key), i, tostring(item2), tostring(newCount), tostring(pcount), tostring(newCount))
      if not DRYRUN then
        writeInteger(tuple + 0x18, newCount)
        if perkData and perkData ~= 0 then writeInteger(perkData + 0x30, newCount) end
      end
    end
    if saveEntry then
      if saveCount < newCount then
        saveChanged = saveChanged + 1
        out[#out+1] = string.format('persist %s save %s->%s', id, tostring(saveCount), tostring(newCount))
        if not DRYRUN then writeInteger(saveEntry.entry + 0x10, newCount) end
      end
    elseif id and id ~= '' then
      saveMissing = saveMissing + 1
    end
  end
end
out[#out+1] = string.format('OK seen=%d changed=%d saveChanged=%d saveMissing=%d dryrun=%s', seen, changed, saveChanged, saveMissing, tostring(DRYRUN))
return table.concat(out, '\n')
