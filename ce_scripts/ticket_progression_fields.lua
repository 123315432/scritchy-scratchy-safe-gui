-- ticket_progression_fields.lua - whitelist read/write one ticket progression entry
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local MODE = tostring(SCRITCHY_TICKET_PROGRESS_MODE or 'status')
if MODE ~= 'status' and MODE ~= 'apply' then return 'ERR: SCRITCHY_TICKET_PROGRESS_MODE must be status/apply, got=' .. MODE end
local TARGET_TICKET = tostring(SCRITCHY_TICKET_ID or '')
local TARGET_LEVEL = SCRITCHY_TICKET_LEVEL
local TARGET_XP = SCRITCHY_TICKET_XP
if TARGET_TICKET == '' then return 'ERR: SCRITCHY_TICKET_ID required' end

local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function rstr(p) if not p or p == 0 then return nil end return readString(p + 0x14, 256, true) end
local function wanted(v) return v ~= nil and tostring(v) ~= '' end
local function clampInt(v, lo, hi)
  v = tonumber(v)
  if not v then return nil end
  if v < lo then v = lo end
  if v > hi then v = hi end
  return math.floor(v)
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
        if p and p ~= 0 then
          rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', p)
          return p, 'mono_static'
        end
      end
    end
  end
  return nil, 'not_found'
end
local function findTicket(dict, ticketId)
  local entries = dict and readQword(dict + 0x18) or nil
  if not entries or entries == 0 then return nil, nil, 'no_entries' end
  local arrlen = readInteger(entries + 0x18) or 0
  for i=0,arrlen-1 do
    local e = entries + 0x20 + i * 24
    local hash = readInteger(e)
    local key = readQword(e + 8)
    local val = readQword(e + 16)
    local name = rstr(key)
    if hash and hash >= 0 and val and val ~= 0 and name == ticketId then
      return key, val, nil
    end
  end
  return nil, nil, 'ticket_not_found'
end

local saveData, source = getSaveData()
if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end
local layerOne = readQword(saveData + 0x30)
if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData=' .. hx(saveData) end
local dict = readQword(layerOne + 0x20)
if not dict or dict == 0 then return 'ERR: ticketProgressionDict nil layerOne=' .. hx(layerOne) end
local key, val, err = findTicket(dict, TARGET_TICKET)
if not val or val == 0 then return 'ERR: ' .. tostring(err) .. ' ticket=' .. TARGET_TICKET end

local levelBefore = readInteger(val + 0x1C)
local xpBefore = readInteger(val + 0x18)
if MODE == 'apply' and wanted(TARGET_LEVEL) then
  local level = clampInt(TARGET_LEVEL, 0, 100000)
  if level ~= nil then writeInteger(val + 0x1C, level) end
end
if MODE == 'apply' and wanted(TARGET_XP) then
  local xp = clampInt(TARGET_XP, 0, 2147483647)
  if xp ~= nil then writeInteger(val + 0x18, xp) end
end
local levelAfter = readInteger(val + 0x1C)
local xpAfter = readInteger(val + 0x18)

return string.format('ticket progression saveData=%s source=%s layerOne=%s dict=%s ticket=%s key=%s val=%s mode=%s level %s -> %s xp %s -> %s',
  hx(saveData), tostring(source), hx(layerOne), hx(dict), TARGET_TICKET, hx(key), hx(val), MODE,
  tostring(levelBefore), tostring(levelAfter), tostring(xpBefore), tostring(xpAfter))
