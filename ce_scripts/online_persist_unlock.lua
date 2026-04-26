-- online_persist_unlock.lua - live SaveData container mutation via pointer chains
-- Safe strategy:
--   * no ActivatePerk / DebugTools native calls
--   * mutate existing TicketProgressionData objects in ticketProgressionDict
--   * reuse existing managed List<string> for superJackpotsGotten to avoid fake managed allocations
--   * wait for game autosave to persist
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local TARGET_LEVEL = tonumber(SCRITCHY_UNLOCK_LEVEL or 30) or 30
local TARGET_XP = tonumber(SCRITCHY_UNLOCK_XP or 9999) or 9999
local MIRROR_SUPER_JACKPOTS = (SCRITCHY_MIRROR_SUPER_JACKPOTS == true)

local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function rstr(p)
  if not p or p == 0 then return nil end
  return readString(p + 0x14, 256, true)
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
    local currentOffset = rawget(_G, 'SCRITCHY_SAVEDATA_CURRENT_OFFSET')
    if saddr and saddr ~= 0 then
      rawset(_G, 'SCRITCHY_SAVEDATA_STATIC_ADDR', saddr)
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
        if p and p ~= 0 then
          rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', p)
          return p, 'mono_static'
        end
      end
    end
  end

  local ok, ptr = pcall(function() return executeMethod(0, 750, base + 0x4D02F0, {type=0, value=0}) end)
  if ok and ptr and ptr ~= 0 then
    rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', ptr)
    return ptr, 'method'
  end
  return nil, 'not_found'
end
local function listInfo(ptr)
  if not ptr or ptr == 0 then return {ptr=ptr, size=-1, cap=-1} end
  local items = readQword(ptr + 0x10)
  local size = readInteger(ptr + 0x18, 4)
  local ver = readInteger(ptr + 0x1C, 4)
  local cap = (items and items ~= 0) and readInteger(items + 0x18, 4) or -1
  return {ptr=ptr, items=items, size=size, ver=ver, cap=cap}
end
local function listContains(info, text)
  if not info.items or info.items == 0 or not info.size or info.size < 1 then return false end
  for i=0,info.size-1 do
    local sp = readQword(info.items + 0x20 + i*8)
    if rstr(sp) == text then return true end
  end
  return false
end
local function listAppendPtr(info, sp)
  if not info.items or info.items == 0 then return false, 'no_items' end
  if not info.size or not info.cap or info.size >= info.cap then return false, 'full' end
  writeQword(info.items + 0x20 + info.size*8, sp)
  writeInteger(info.ptr + 0x18, info.size + 1)
  writeInteger(info.ptr + 0x1C, (info.ver or 0) + 1)
  info.size = info.size + 1
  info.ver = (info.ver or 0) + 1
  return true
end
local function walkTicketProgressionDict(dict, cb)
  local entries = readQword(dict + 0x18)
  if not entries or entries == 0 then return 0, 'no_entries' end
  local arrlen = readInteger(entries + 0x18, 4)
  local touched = 0
  for i=0,(arrlen or 0)-1 do
    local e = entries + 0x20 + i*24
    local hash = readInteger(e, 4)
    local key = readQword(e + 8)
    local val = readQword(e + 16)
    if hash and hash >= 0 and key and key ~= 0 and val and val ~= 0 then
      local name = rstr(key)
      if name and name ~= '' then
        cb(name, key, val)
        touched = touched + 1
      end
    end
  end
  return touched
end

local saveData, source = getSaveData()
if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end
local layerOne = readQword(saveData + 0x30)
if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData=' .. hx(saveData) end

-- scalar gates
writeInteger(saveData + 0x38, math.max(readInteger(saveData + 0x38, 4) or 0, 99))
writeInteger(saveData + 0x3C, math.max(readInteger(saveData + 0x3C, 4) or 0, 999999))
writeInteger(saveData + 0x40, math.max(readInteger(saveData + 0x40, 4) or 0, 5))
writeDouble(saveData + 0xC8, math.max(readDouble(saveData + 0xC8) or 0, 999999999.0))
writeDouble(layerOne + 0x10, math.max(readDouble(layerOne + 0x10) or 0, 1.0e40))
writeDouble(layerOne + 0x50, math.max(readDouble(layerOne + 0x50) or 0, 1.0e30))
writeInteger(layerOne + 0x88, math.max(readInteger(layerOne + 0x88, 4) or 0, 999999))

local progressDict = readQword(layerOne + 0x20)
local jackpots = readQword(layerOne + 0x40)
local superJackpots = readQword(layerOne + 0x48)
local jpInfo = listInfo(jackpots)
local sjpBefore = listInfo(superJackpots)

local progressTouched = 0
local jackpotAdded = 0
local jackpotSkipped = 0
local mainTicketSet = {
  ['Two Win']=true, ['Mini Scratch']=true, ['Apple Tree']=true, ['Quick Cash']=true, ['Lucky Cat']=true,
  ['Sand Dollars']=true, ['Scratch My Back']=true, ['Snake Eyes']=true, ['The Bomb']=true,
  ['Bank Break']=true, ['Xmas Countdown']=true, ['Thrift Store']=true, ['Berry Picking']=true,
  ['Trick or Treat']=true, ['Slot Machine']=true, ['To the Moon']=true, ['Booster Pack']=true,
}
local dictCount, dictErr = walkTicketProgressionDict(progressDict, function(name, keyPtr, valPtr)
  local oldLevel = readInteger(valPtr + 0x1C, 4) or 0
  local oldXp = readInteger(valPtr + 0x18, 4) or 0
  if oldLevel < TARGET_LEVEL then writeInteger(valPtr + 0x1C, TARGET_LEVEL) end
  if oldXp < TARGET_XP then writeInteger(valPtr + 0x18, TARGET_XP) end
  progressTouched = progressTouched + 1
  if mainTicketSet[name] then
    if listContains(jpInfo, name) then
      jackpotSkipped = jackpotSkipped + 1
    else
      local ok = listAppendPtr(jpInfo, keyPtr)
      if ok then jackpotAdded = jackpotAdded + 1 end
    end
  end
end)

if MIRROR_SUPER_JACKPOTS then
  -- Same managed List<string> object. Avoids allocating/expanding a List while giving autosave a complete SJP history list.
  writeQword(layerOne + 0x48, jackpots)
end
local sjpAfter = listInfo(readQword(layerOne + 0x48))
local jpAfter = listInfo(readQword(layerOne + 0x40))

return string.format('OK saveData=%s source=%s layerOne=%s progressDict=%s dictCount=%s progressTouched=%d level=%d xp=%d jackpots=%s size %s->%s added=%d skipped=%d superJackpots %s size %s->%s mirrored=%s',
  hx(saveData), tostring(source), hx(layerOne), hx(progressDict), tostring(dictCount or dictErr), progressTouched, TARGET_LEVEL, TARGET_XP,
  hx(jackpots), tostring(jpInfo.size), tostring(jpAfter.size), jackpotAdded, jackpotSkipped,
  hx(readQword(layerOne+0x48)), tostring(sjpBefore.size), tostring(sjpAfter.size), tostring(MIRROR_SUPER_JACKPOTS))

