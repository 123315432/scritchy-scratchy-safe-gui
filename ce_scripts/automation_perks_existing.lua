-- automation_perks_existing.lua - safe existing-entry automation perk updater
-- Whitelist only: HandsOff(19), FullyAutomated(36). Does not add entries, does not call ActivatePerk.
openProcess('ScritchyScratchy.exe')
pcall(LaunchMonoDataCollector)

local MODE = tostring(SCRITCHY_AUTOMATION_PERK_MODE or 'status')
local DRYRUN = (MODE ~= 'apply')
local TARGET_COUNT = tonumber(SCRITCHY_AUTOMATION_PERK_COUNT or 1) or 1
if TARGET_COUNT < 1 then TARGET_COUNT = 1 end

local TARGET_TYPES = {
  [19] = 'HandsOff',
  [36] = 'FullyAutomated',
}
local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function safeString(sp)
  if sp and sp ~= 0 and sp < 0x0000800000000000 then return readString(sp + 0x14, 128, true) end
  return nil
end
local function getSaveData()
  local cached = rawget(_G, 'SCRITCHY_CACHED_SAVEDATA')
  if cached and cached ~= 0 then
    local layer = readQword(cached + 0x30)
    if layer and layer ~= 0 then return cached, 'cache' end
    rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', nil)
  end
  local cls = mono_findClass('', 'SaveData')
  if not cls then return nil, 'not_found' end
  local saddr = rawget(_G, 'SCRITCHY_SAVEDATA_STATIC_ADDR') or mono_class_getStaticFieldAddress(0, cls)
  if not saddr or saddr == 0 then return nil, 'static_not_found' end
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
  if not currentOffset then return nil, 'current_offset_not_found' end
  local p = readQword(saddr + currentOffset)
  if p and p ~= 0 then rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', p); return p, 'mono_static' end
  return nil, 'current_nil'
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
local out = {string.format('automation perks manager=%s dict=%s entries=%s saveData=%s saveInfo=%s mode=%s dryrun=%s', hx(manager), hx(dict), hx(entries), hx(saveData), tostring(saveInfo), MODE, tostring(DRYRUN))}
local seen = {[19]=false, [36]=false}
local changed, saveChanged = 0, 0
for i=0,(arrlen or 0)-1 do
  local entry = entries + 0x20 + i * 0x18
  local hash = readInteger(entry, 4)
  local key = readInteger(entry + 0x08, 4)
  local tuple = readQword(entry + 0x10)
  if hash and hash >= 0 and tuple and tuple ~= 0 and tuple < 0x0000800000000000 and TARGET_TYPES[key] then
    seen[key] = true
    local perkData = readQword(tuple + 0x10)
    local item2 = readInteger(tuple + 0x18, 4) or 0
    local id, ptype, pcount = TARGET_TYPES[key], key, nil
    if perkData and perkData ~= 0 and perkData < 0x0000800000000000 then
      id = safeString(readQword(perkData + 0x10)) or id
      ptype = readInteger(perkData + 0x18, 4) or ptype
      pcount = readInteger(perkData + 0x30, 4) or 0
    end
    local target = math.max(item2, pcount or 0, TARGET_COUNT)
    out[#out+1] = string.format('%s type=%s tupleItem2 %s->%s perkCount %s->%s entry=%d', tostring(id), tostring(ptype), tostring(item2), tostring(target), tostring(pcount), tostring(target), i)
    if target ~= item2 or (pcount and target ~= pcount) then
      changed = changed + 1
      if not DRYRUN then
        writeInteger(tuple + 0x18, target)
        if perkData and perkData ~= 0 then writeInteger(perkData + 0x30, target) end
      end
    end
    local saveEntry = id and saveIndex[id] or nil
    if saveEntry and saveEntry.value < target then
      saveChanged = saveChanged + 1
      out[#out+1] = string.format('persist %s save %s->%s', id, tostring(saveEntry.value), tostring(target))
      if not DRYRUN then writeInteger(saveEntry.entry + 0x10, target) end
    elseif not saveEntry then
      out[#out+1] = string.format('persist %s not_found_existing_only', tostring(id))
    end
  end
end
for ptype, name in pairs(TARGET_TYPES) do
  if not seen[ptype] then out[#out+1] = string.format('%s type=%d not_found_existing_only', name, ptype) end
end
out[#out+1] = string.format('OK changed=%d saveChanged=%d dryrun=%s', changed, saveChanged, tostring(DRYRUN))
return table.concat(out, '\n')
