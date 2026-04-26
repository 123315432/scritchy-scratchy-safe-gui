-- single_perk_fields.lua - safe editor for one existing perk entry only
-- No dictionary expansion, no managed object creation, no ActivatePerk.
openProcess('ScritchyScratchy.exe')
pcall(LaunchMonoDataCollector)

local MODE = tostring(SCRITCHY_SINGLE_PERK_MODE or 'status')
if MODE ~= 'status' and MODE ~= 'apply' then return 'ERR: SCRITCHY_SINGLE_PERK_MODE must be status/apply, got=' .. MODE end
local TARGET = tostring(SCRITCHY_SINGLE_PERK_TARGET or '')
local TARGET_COUNT = tonumber(SCRITCHY_SINGLE_PERK_COUNT)
local TUPLE_COUNT = tonumber(SCRITCHY_SINGLE_PERK_TUPLE_COUNT)
local PERKDATA_COUNT = tonumber(SCRITCHY_SINGLE_PERK_PERKDATA_COUNT)
local SAVE_COUNT = tonumber(SCRITCHY_SINGLE_PERK_SAVE_COUNT)
local TARGET_TYPE = tonumber(TARGET)
if TARGET == '' then return 'ERR: SCRITCHY_SINGLE_PERK_TARGET required' end
if MODE == 'apply' and TARGET_COUNT == nil and TUPLE_COUNT == nil and PERKDATA_COUNT == nil and SAVE_COUNT == nil then
  return 'ERR: SCRITCHY_SINGLE_PERK_COUNT or per-field counts required for apply'
end
if TARGET_COUNT ~= nil then
  if TARGET_COUNT < 0 then TARGET_COUNT = 0 end
  if TARGET_COUNT > 100000 then TARGET_COUNT = 100000 end
  TARGET_COUNT = math.floor(TARGET_COUNT)
end
local function normalizeCount(v)
  if v == nil then return nil end
  if v < 0 then v = 0 end
  if v > 100000 then v = 100000 end
  return math.floor(v)
end
TUPLE_COUNT = normalizeCount(TUPLE_COUNT)
PERKDATA_COUNT = normalizeCount(PERKDATA_COUNT)
SAVE_COUNT = normalizeCount(SAVE_COUNT)

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
  local cls = mono_findClass and mono_findClass('', 'SaveData')
  if not cls then return nil, 'class_not_found' end
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
  if not entries or entries == 0 then return index, 'no_entries dict=' .. hx(dict) end
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

local cls = mono_findClass and mono_findClass('', 'PerkManager')
if not cls then return 'ERR: PerkManager class not found' end
local manager = (mono_class_findInstancesOfClassListOnly(nil, cls) or {})[1]
if not manager or manager == 0 then return 'ERR: PerkManager instance not found' end
local dict = readQword(manager + 0x28)
local entries = dict and readQword(dict + 0x18) or nil
if not entries or entries == 0 then return 'ERR: activePerks entries not found manager=' .. hx(manager) .. ' dict=' .. hx(dict) end

local saveData, saveSource = getSaveData()
local saveIndex, saveInfo = indexBoughtPrestigeUpgrades(saveData)
local arrlen = readInteger(entries + 0x18, 4) or 0
local match = nil
local seen = 0
for i=0,arrlen-1 do
  local entry = entries + 0x20 + i * 0x18
  local hash = readInteger(entry, 4)
  local key = readInteger(entry + 0x08, 4)
  local tuple = readQword(entry + 0x10)
  if hash and hash >= 0 and tuple and tuple ~= 0 and tuple < 0x0000800000000000 then
    local perkData = readQword(tuple + 0x10)
    local item2 = readInteger(tuple + 0x18, 4) or 0
    local id, ptype, pcount = nil, key, nil
    if perkData and perkData ~= 0 and perkData < 0x0000800000000000 then
      id = safeString(readQword(perkData + 0x10))
      ptype = readInteger(perkData + 0x18, 4) or key
      pcount = readInteger(perkData + 0x30, 4) or 0
    end
    seen = seen + 1
    if (TARGET_TYPE ~= nil and (key == TARGET_TYPE or ptype == TARGET_TYPE)) or (id == TARGET) then
      match = {entry=entry, key=key, tuple=tuple, perkData=perkData, id=id, ptype=ptype, item2=item2, pcount=pcount, index=i}
      break
    end
  end
end

if not match then return string.format('ERR: target perk not found existing_only target=%s seen=%d manager=%s', TARGET, seen, hx(manager)) end
if not match.id or match.id == '' then return 'ERR: target perk has no id entry=' .. tostring(match.index) end
local saveEntry = saveIndex[match.id]
if not saveEntry then return string.format('ERR: save entry not found existing_only id=%s type=%s saveInfo=%s', tostring(match.id), tostring(match.ptype), tostring(saveInfo)) end
local saveBefore = saveEntry.value

if MODE == 'apply' then
  local tupleTarget = TUPLE_COUNT ~= nil and TUPLE_COUNT or TARGET_COUNT
  local perkTarget = PERKDATA_COUNT ~= nil and PERKDATA_COUNT or TARGET_COUNT
  local saveTarget = SAVE_COUNT ~= nil and SAVE_COUNT or TARGET_COUNT
  writeInteger(match.tuple + 0x18, tupleTarget)
  if match.perkData and match.perkData ~= 0 then writeInteger(match.perkData + 0x30, perkTarget) end
  writeInteger(saveEntry.entry + 0x10, saveTarget)
end

local itemAfter = readInteger(match.tuple + 0x18, 4) or 0
local perkAfter = (match.perkData and match.perkData ~= 0) and (readInteger(match.perkData + 0x30, 4) or 0) or -1
local saveAfter = readInteger(saveEntry.entry + 0x10, 4) or 0
local tupleExpected = TUPLE_COUNT ~= nil and TUPLE_COUNT or TARGET_COUNT
local perkExpected = PERKDATA_COUNT ~= nil and PERKDATA_COUNT or TARGET_COUNT
local saveExpected = SAVE_COUNT ~= nil and SAVE_COUNT or TARGET_COUNT
local changed = MODE == 'apply' and itemAfter == tupleExpected and perkAfter == perkExpected and saveAfter == saveExpected
return string.format('single perk manager=%s saveData=%s saveSource=%s saveInfo=%s mode=%s target=%s entry=%d id=%s type=%s tuple=%s perkData=%s tupleItem2 %s -> %s perkCount %s -> %s save %s -> %s changed=%s',
  hx(manager), hx(saveData), tostring(saveSource), tostring(saveInfo), MODE, TARGET, match.index, tostring(match.id), tostring(match.ptype),
  hx(match.tuple), hx(match.perkData), tostring(match.item2), tostring(itemAfter), tostring(match.pcount), tostring(perkAfter),
  tostring(saveBefore), tostring(saveAfter), tostring(changed))
