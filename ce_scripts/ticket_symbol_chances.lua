-- ticket_symbol_chances.lua - per-ticket / per-symbol chance inspection and live edits
-- Read mode:
--   SCRITCHY_SYMBOL_MODE='dump'
-- Apply mode:
--   SCRITCHY_SYMBOL_MODE='apply'
--   SCRITCHY_SYMBOL_TICKET='Lucky Cat'
--   SCRITCHY_SYMBOL_ID='Lucky Cat Jackpot'
--   SCRITCHY_SYMBOL_VALUE=99999.0
--   SCRITCHY_SYMBOL_LUCK_INDEX=-1  -- -1 = all chance slots, otherwise one 0-based index
openProcess('ScritchyScratchy.exe')
pcall(LaunchMonoDataCollector)

local MODE = tostring(SCRITCHY_SYMBOL_MODE or 'dump')
local TARGET_TICKET = SCRITCHY_SYMBOL_TICKET and tostring(SCRITCHY_SYMBOL_TICKET) or nil
local TARGET_SYMBOL = SCRITCHY_SYMBOL_ID and tostring(SCRITCHY_SYMBOL_ID) or nil
local TARGET_TYPE = SCRITCHY_SYMBOL_TYPE ~= nil and tonumber(SCRITCHY_SYMBOL_TYPE) or nil
local TARGET_VALUE = tonumber(SCRITCHY_SYMBOL_VALUE or 0) or 0
local LUCK_INDEX = tonumber(SCRITCHY_SYMBOL_LUCK_INDEX or -1) or -1
local DRYRUN = (SCRITCHY_SYMBOL_DRYRUN == true)

local SYMBOL_NAMES = {
  [-1] = '坏符号',
  [0] = '空符号',
  [1] = '小奖',
  [2] = '大奖',
  [3] = '超级大奖',
  [4] = '倍率',
  [5] = '自毁',
}

local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function rstr(p)
  if p and p ~= 0 and p < 0x0000800000000000 then return readString(p + 0x14, 256, true) end
  return nil
end
local function listInfo(ptr, elemSize)
  if not ptr or ptr == 0 then return {ptr=ptr, items=0, size=0, cap=0} end
  local items = readQword(ptr + 0x10) or 0
  local size = readInteger(ptr + 0x18, 4) or 0
  local cap = (items ~= 0) and (readInteger(items + 0x18, 4) or 0) or 0
  return {ptr=ptr, items=items, size=size, cap=cap, elemSize=elemSize or 8}
end
local function listRefAt(info, index)
  if not info.items or info.items == 0 or index < 0 or index >= info.size then return nil end
  return readQword(info.items + 0x20 + index * 8)
end
local function readFloatList(ptr)
  local info = listInfo(ptr, 4)
  local values = {}
  if info.items ~= 0 then
    for i=0,info.size-1 do values[#values+1] = readFloat(info.items + 0x20 + i * 4) or 0 end
  end
  return info, values
end
local function writeFloatList(ptr, value, index)
  local info = listInfo(ptr, 4)
  if info.items == 0 then return 0, 'no_items' end
  local changed = 0
  if index and index >= 0 then
    if index >= info.size then return 0, 'index_out_of_range' end
    if not DRYRUN then writeFloat(info.items + 0x20 + index * 4, value) end
    changed = 1
  else
    for i=0,info.size-1 do
      if not DRYRUN then writeFloat(info.items + 0x20 + i * 4, value) end
      changed = changed + 1
    end
  end
  return changed
end
local function findStaticData()
  local cls = mono_findClass('', 'StaticData')
  if not cls then return nil, 'StaticData class not found' end
  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}
  for _, inst in ipairs(list) do
    local dict = readQword(inst + 0x78)
    local entries = dict and readQword(dict + 0x18) or 0
    local count = dict and readInteger(dict + 0x20, 4) or 0
    if entries and entries ~= 0 and count and count >= 40 then return inst end
  end
  return list[1], 'fallback_instance'
end
local function walkTicketDict(cb)
  local staticData, err = findStaticData()
  if not staticData or staticData == 0 then return 0, 'ERR: ' .. tostring(err) end
  local dict = readQword(staticData + 0x78)
  local entries = dict and readQword(dict + 0x18) or 0
  if not entries or entries == 0 then return 0, 'ERR: ticketData entries nil staticData=' .. hx(staticData) .. ' dict=' .. hx(dict) end
  local arrlen = readInteger(entries + 0x18, 4) or 0
  local count = 0
  for i=0,arrlen-1 do
    local entry = entries + 0x20 + i * 0x18
    local hash = readInteger(entry, 4)
    local key = rstr(readQword(entry + 0x08))
    local ticketData = readQword(entry + 0x10)
    if hash and hash >= 0 and key and key ~= '' and ticketData and ticketData ~= 0 then
      count = count + 1
      cb(key, ticketData)
    end
  end
  return count
end
local function formatFloats(values)
  local out = {}
  for i, v in ipairs(values) do out[#out+1] = string.format('%.6g', v) end
  return table.concat(out, ',')
end

if MODE == 'dump' then
  local out = {'ticket\tsymbolId\ttype\ttypeName\tchanceCount\tchances'}
  local count, err = walkTicketDict(function(ticketKey, ticketData)
    if not TARGET_TICKET or TARGET_TICKET == '' or ticketKey == TARGET_TICKET then
      local symbols = readQword(ticketData + 0x48)
      local sinfo = listInfo(symbols, 8)
      for i=0,sinfo.size-1 do
        local symbol = listRefAt(sinfo, i)
        if symbol and symbol ~= 0 then
          local symbolId = rstr(readQword(symbol + 0x18)) or ''
          local stype = readInteger(symbol + 0x38, 4) or 0
          local _, chances = readFloatList(readQword(symbol + 0x30))
          out[#out+1] = table.concat({ticketKey, symbolId, tostring(stype), SYMBOL_NAMES[stype] or tostring(stype), tostring(#chances), formatFloats(chances)}, '\t')
        end
      end
    end
  end)
  if not count or count == 0 then out[#out+1] = tostring(err or 'ERR: no tickets') end
  return table.concat(out, '\n')
end

if MODE == 'apply' then
  if not TARGET_TICKET or TARGET_TICKET == '' then return 'ERR: SCRITCHY_SYMBOL_TICKET required' end
  if (not TARGET_SYMBOL or TARGET_SYMBOL == '') and TARGET_TYPE == nil then return 'ERR: SCRITCHY_SYMBOL_ID or SCRITCHY_SYMBOL_TYPE required' end
  local touchedSymbols, touchedFloats = 0, 0
  local out = {string.format('apply ticket=%s symbol=%s type=%s value=%s luckIndex=%s dryrun=%s', tostring(TARGET_TICKET), tostring(TARGET_SYMBOL), tostring(TARGET_TYPE), tostring(TARGET_VALUE), tostring(LUCK_INDEX), tostring(DRYRUN))}
  walkTicketDict(function(ticketKey, ticketData)
    if ticketKey == TARGET_TICKET then
      local symbols = readQword(ticketData + 0x48)
      local sinfo = listInfo(symbols, 8)
      for i=0,sinfo.size-1 do
        local symbol = listRefAt(sinfo, i)
        if symbol and symbol ~= 0 then
          local symbolId = rstr(readQword(symbol + 0x18)) or ''
          local stype = readInteger(symbol + 0x38, 4) or 0
          if (TARGET_SYMBOL and TARGET_SYMBOL ~= '' and symbolId == TARGET_SYMBOL) or (TARGET_TYPE ~= nil and stype == TARGET_TYPE) then
            local cptr = readQword(symbol + 0x30)
            local _, before = readFloatList(cptr)
            local changed, werr = writeFloatList(cptr, TARGET_VALUE, LUCK_INDEX)
            local _, after = readFloatList(cptr)
            touchedSymbols = touchedSymbols + 1
            touchedFloats = touchedFloats + (changed or 0)
            out[#out+1] = string.format('%s / %s type=%s %s -> %s changed=%s err=%s', ticketKey, symbolId, tostring(stype), formatFloats(before), formatFloats(after), tostring(changed), tostring(werr))
          end
        end
      end
    end
  end)
  return table.concat(out, '\n') .. string.format('\nOK touchedSymbols=%d touchedFloats=%d', touchedSymbols, touchedFloats)
end

return 'ERR unknown SCRITCHY_SYMBOL_MODE=' .. tostring(MODE)
