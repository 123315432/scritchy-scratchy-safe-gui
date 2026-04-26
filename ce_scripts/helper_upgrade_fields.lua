-- helper_upgrade_fields.lua - whitelist read/write helper upgrade counts in LayerOne.upgradeDataDict
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local MODE = tostring(SCRITCHY_HELPER_UPGRADE_MODE or 'status')
if MODE ~= 'status' and MODE ~= 'apply' then return 'ERR: SCRITCHY_HELPER_UPGRADE_MODE must be status/apply, got=' .. MODE end

local TARGET_NAMES = {'Fan','Fan Speed','Fan Battery','Mundo','Mundo Speed','Spell Book','Spell Charge Speed','Egg Timer','Timer Capacity','Timer Charge','Warp Speed'}
local TARGETS = {
  ['Fan'] = SCRITCHY_UPGRADE_FAN,
  ['Fan Speed'] = SCRITCHY_UPGRADE_FAN_SPEED,
  ['Fan Battery'] = SCRITCHY_UPGRADE_FAN_BATTERY,
  ['Mundo'] = SCRITCHY_UPGRADE_MUNDO,
  ['Mundo Speed'] = SCRITCHY_UPGRADE_MUNDO_SPEED,
  ['Spell Book'] = SCRITCHY_UPGRADE_SPELL_BOOK,
  ['Spell Charge Speed'] = SCRITCHY_UPGRADE_SPELL_CHARGE_SPEED,
  ['Egg Timer'] = SCRITCHY_UPGRADE_EGG_TIMER,
  ['Timer Capacity'] = SCRITCHY_UPGRADE_TIMER_CAPACITY,
  ['Timer Charge'] = SCRITCHY_UPGRADE_TIMER_CHARGE,
  ['Warp Speed'] = SCRITCHY_UPGRADE_WARP_SPEED,
}
local MAX_COUNTS = {
  ['Fan'] = 1,
  ['Fan Speed'] = 5,
  ['Fan Battery'] = 5,
  ['Mundo'] = 1,
  ['Mundo Speed'] = 10,
  ['Spell Book'] = 1,
  ['Spell Charge Speed'] = 10,
  ['Egg Timer'] = 1,
  ['Timer Capacity'] = 10,
  ['Timer Charge'] = 10,
  ['Warp Speed'] = 3,
}
local MAX_SOURCE = 'fallback'

local function scriptRoot()
  local source = debug.getinfo(1, 'S').source or ''
  local path = source:gsub('^@', '')
  return path:match('^(.*[\\/])') or ''
end
local function readAll(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end
local function escapePattern(s)
  return s:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1')
end
local function loadMaxCounts()
  local data = readAll(scriptRoot() .. '..\\analysis\\UpgradeData.json')
  if not data then return end
  local loaded = 0
  for _, name in ipairs(TARGET_NAMES) do
    local block = data:match('"' .. escapePattern(name) .. '"%s*:%s*{(.-)}')
    local v = block and tonumber(block:match('"upgradeCount"%s*:%s*([%d%.]+)'))
    if v then
      MAX_COUNTS[name] = math.floor(v)
      loaded = loaded + 1
    end
  end
  if loaded > 0 then MAX_SOURCE = 'analysis/UpgradeData.json' end
end
loadMaxCounts()

local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function rstr(p) if not p or p == 0 then return nil end return readString(p + 0x14, 256, true) end
local function wanted(v) return v ~= nil and tostring(v) ~= '' end
local function clampCount(name, v)
  v = tonumber(v)
  if not v then return nil end
  if v < 0 then v = 0 end
  local maxv = MAX_COUNTS[name]
  if maxv and v > maxv then v = maxv end
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

local saveData, source = getSaveData()
if not saveData or saveData == 0 then return 'ERR: SaveData nil source=' .. tostring(source) end
local layerOne = readQword(saveData + 0x30)
if not layerOne or layerOne == 0 then return 'ERR: layerOne nil saveData=' .. hx(saveData) end
local dict = readQword(layerOne + 0x28)
local entries = dict and readQword(dict + 0x18) or nil
if not entries or entries == 0 then return 'ERR: upgradeDataDict entries nil dict=' .. hx(dict) end

local arrlen = readInteger(entries + 0x18) or 0
local out = {string.format('helper upgrades saveData=%s source=%s layerOne=%s dict=%s mode=%s max_source=%s', hx(saveData), tostring(source), hx(layerOne), hx(dict), MODE, MAX_SOURCE)}
local seen = {}
for i=0,arrlen-1 do
  local e = entries + 0x20 + i * 24
  local hash = readInteger(e)
  local key = readQword(e + 8)
  local val = readQword(e + 16)
  local name = rstr(key)
  if hash and hash >= 0 and val and val ~= 0 and MAX_COUNTS[name] ~= nil then
    seen[name] = true
    local before = readInteger(val + 0x18)
    if MODE == 'apply' and wanted(TARGETS[name]) then
      local target = clampCount(name, TARGETS[name])
      if target ~= nil then writeInteger(val + 0x18, target) end
    end
    local after = readInteger(val + 0x18)
    out[#out+1] = string.format('%s %s -> %s max=%s val=%s', name, tostring(before), tostring(after), tostring(MAX_COUNTS[name]), hx(val))
  end
end
for _, name in ipairs(TARGET_NAMES) do
  if not seen[name] then out[#out+1] = name .. ' not_found' end
end
return table.concat(out, '\n')
