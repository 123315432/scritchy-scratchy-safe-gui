-- bot_upgrade_fields.lua - whitelist read/write Scratch Bot upgrade counts in LayerOne.upgradeDataDict
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local MODE = tostring(SCRITCHY_BOT_MODE or 'status')
local TARGET_NAMES = {'Scratch Bot', 'Scratch Bot Speed', 'Scratch Bot Capacity', 'Scratch Bot Strength'}
local TARGETS = {
  ['Scratch Bot'] = SCRITCHY_BOT_UNLOCK,
  ['Scratch Bot Speed'] = SCRITCHY_BOT_SPEED,
  ['Scratch Bot Capacity'] = SCRITCHY_BOT_CAPACITY,
  ['Scratch Bot Strength'] = SCRITCHY_BOT_STRENGTH,
}
local MAX_COUNTS = {
  ['Scratch Bot'] = 1,
  ['Scratch Bot Speed'] = 30,
  ['Scratch Bot Capacity'] = 10,
  ['Scratch Bot Strength'] = 20,
}
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
  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', 'SaveData')
  if cls then
    local saddr = mono_class_getStaticFieldAddress(0, cls)
    if saddr and saddr ~= 0 then
      for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do
        if f.name == '_current' or f.name == 'current' then
          local p = readQword(saddr + f.offset)
          if p and p ~= 0 then return p, 'mono_static' end
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
local arrlen = readInteger(entries + 0x18, 4) or 0
local out = {string.format('bot upgrades saveData=%s source=%s layerOne=%s dict=%s mode=%s', hx(saveData), tostring(source), hx(layerOne), hx(dict), MODE)}
local seen = {}
for i=0,arrlen-1 do
  local e = entries + 0x20 + i * 24
  local hash = readInteger(e, 4)
  local key = readQword(e + 8)
  local val = readQword(e + 16)
  local name = rstr(key)
  if hash and hash >= 0 and val and val ~= 0 and MAX_COUNTS[name] ~= nil then
    seen[name] = true
    local before = readInteger(val + 0x18, 4)
    if MODE == 'apply' and wanted(TARGETS[name]) then
      local target = clampCount(name, TARGETS[name])
      if target ~= nil then writeInteger(val + 0x18, target) end
    end
    local after = readInteger(val + 0x18, 4)
    out[#out+1] = string.format('%s %s -> %s max=%s val=%s', name, tostring(before), tostring(after), tostring(MAX_COUNTS[name]), hx(val))
  end
end
for _, name in ipairs(TARGET_NAMES) do
  if not seen[name] then out[#out+1] = name .. ' not_found' end
end
return table.concat(out, '\n')
