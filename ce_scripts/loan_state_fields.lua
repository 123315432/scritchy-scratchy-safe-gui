-- loan_state_fields.lua - safe loan list/count reader-writer
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local MODE = tostring(SCRITCHY_LOAN_MODE or 'status')
if MODE ~= 'status' and MODE ~= 'apply' and MODE ~= 'clear' then return 'ERR: SCRITCHY_LOAN_MODE must be status/apply/clear, got=' .. MODE end

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
local function clampDouble(v, lo, hi)
  v = tonumber(v)
  if not v then return nil end
  if v < lo then v = lo end
  if v > hi then v = hi end
  return v
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

local function listInfo(list)
  if not list or list == 0 then return {list=list or 0, items=0, size=0, capacity=0} end
  local items = readQword(list + 0x10) or 0
  local size = readInteger(list + 0x18) or 0
  local capacity = 0
  if items ~= 0 then capacity = readInteger(items + 0x18) or 0 end
  return {list=list, items=items, size=size, capacity=capacity}
end

local function listGet(info, index)
  if not info or info.items == 0 or index < 0 or index >= info.capacity then return 0 end
  return readQword(info.items + 0x20 + index * 8) or 0
end

local saveData, source = getSaveData()
if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end
local layerOne = readQword(saveData + 0x30)
if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData=' .. hx(saveData) end

local loans = readQword(layerOne + 0x70)
local info = listInfo(loans)
local loanCountBefore = readInteger(saveData + 0xC0)
local sizeBefore = info.size

if MODE == 'clear' then
  writeInteger(saveData + 0xC0, 0)
  if info.list ~= 0 then writeInteger(info.list + 0x18, 0) end
elseif MODE == 'apply' then
  if wanted(SCRITCHY_LOAN_COUNT) then
    local targetLoanCount = clampInt(SCRITCHY_LOAN_COUNT, 0, 100000)
    if targetLoanCount ~= nil then writeInteger(saveData + 0xC0, targetLoanCount) end
  end
  if wanted(SCRITCHY_LOAN_LIST_SIZE) and info.list ~= 0 then
    local targetSize = clampInt(SCRITCHY_LOAN_LIST_SIZE, 0, info.capacity)
    if targetSize ~= nil then writeInteger(info.list + 0x18, targetSize) end
  end
  local first = listGet(info, 0)
  if first ~= 0 then
    if wanted(SCRITCHY_LOAN_INDEX) then
      local v = clampInt(SCRITCHY_LOAN_INDEX, 0, 100000)
      if v ~= nil then writeInteger(first + 0x18, v) end
    end
    if wanted(SCRITCHY_LOAN_NUM) then
      local v = clampInt(SCRITCHY_LOAN_NUM, 0, 100000)
      if v ~= nil then writeInteger(first + 0x1C, v) end
    end
    if wanted(SCRITCHY_LOAN_SEVERITY) then
      local v = clampInt(SCRITCHY_LOAN_SEVERITY, 0, 100000)
      if v ~= nil then writeInteger(first + 0x20, v) end
    end
    if wanted(SCRITCHY_LOAN_AMOUNT) then
      local v = clampDouble(SCRITCHY_LOAN_AMOUNT, 0, 1.0e100)
      if v ~= nil then writeDouble(first + 0x28, v) end
    end
  end
end

local infoAfter = listInfo(readQword(layerOne + 0x70))
local loanCountAfter = readInteger(saveData + 0xC0)
local out = {string.format('loan state saveData=%s source=%s layerOne=%s loans=%s items=%s capacity=%s mode=%s loanCount %s -> %s listSize %s -> %s',
  hx(saveData), tostring(source), hx(layerOne), hx(infoAfter.list), hx(infoAfter.items), tostring(infoAfter.capacity), MODE,
  tostring(loanCountBefore), tostring(loanCountAfter), tostring(sizeBefore), tostring(infoAfter.size))}

local displayCount = infoAfter.size
if displayCount > 8 then displayCount = 8 end
for i=0,displayCount-1 do
  local loan = listGet(infoAfter, i)
  if loan and loan ~= 0 then
    out[#out+1] = string.format('loan[%d] ptr=%s id=%s index=%s loanNum=%s severity=%s amount=%s',
      i, hx(loan), tostring(rstr(readQword(loan + 0x10))), tostring(readInteger(loan + 0x18)),
      tostring(readInteger(loan + 0x1C)), tostring(readInteger(loan + 0x20)), tostring(readDouble(loan + 0x28)))
  else
    out[#out+1] = string.format('loan[%d] ptr=nil', i)
  end
end
if infoAfter.size > displayCount then out[#out+1] = string.format('... %d more loans not shown', infoAfter.size - displayCount) end
return table.concat(out, '\n')
