-- runtime_status.lua - read-only current runtime status summary
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function b(v) return v and v ~= 0 and 'true' or 'false' end
local function rstr(p)
  if not p or p == 0 then return nil end
  return readString(p + 0x14, 256, true)
end
local function findInstance(className)
  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', className)
  if not cls then return nil end
  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}
  return list[1]
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
          if p and p ~= 0 then return p end
        end
      end
    end
  end
  return nil
end

local out = {}
local saveData = getSaveData()
if saveData and saveData ~= 0 then
  local layerOne = readQword(saveData + 0x30)
  out[#out+1] = string.format('存档: saveData=%s layerOne=%s prestige=%s prestigeCurrency=%s act=%s tokens=%s', hx(saveData), hx(layerOne), tostring(readInteger(saveData+0x38,4)), tostring(readInteger(saveData+0x3C,4)), tostring(readInteger(saveData+0x40,4)), tostring(readDouble(saveData+0xC8)))
  if layerOne and layerOne ~= 0 then
    out[#out+1] = string.format('资源: money=%s souls=%s machineTier=%s machineFeed=%s', tostring(readDouble(layerOne+0x10)), tostring(readInteger(layerOne+0x88,4)), tostring(readInteger(layerOne+0x7C,4)), tostring(readInteger(layerOne+0x80,4)))
  end
else
  out[#out+1] = '存档: SaveData 未找到'
end

local scratching = findInstance('PlayerScratching')
if scratching and scratching ~= 0 then
  local tool = readQword(scratching + 0x28)
  local ticket = readQword(scratching + 0xC8)
  out[#out+1] = string.format('刮卡: PlayerScratching=%s tool=%s currentTicket=%s checks=%s luck=%s luckReduction=%s', hx(scratching), hx(tool), hx(ticket), tostring(readInteger(scratching+0x4C,4)), tostring(readInteger(scratching+0x94,4)), tostring(readInteger(scratching+0x98,4)))
  if tool and tool ~= 0 then
    out[#out+1] = string.format('工具: strength=%s sizeBacking=%s sizeReduction=%s', tostring(readInteger(tool+0x28,4)), tostring(readInteger(tool+0x30,4)), tostring(readInteger(tool+0x34,4)))
  end
  if ticket and ticket ~= 0 then
    local data = readQword(ticket + 0xC8)
    local id = data and rstr(readQword(data + 0x10)) or nil
    out[#out+1] = string.format('当前票: ticket=%s data=%s id=%s autoScratched=%s allScratched=%s isJackpot=%s triggeredSJP=%s', hx(ticket), hx(data), tostring(id), b(readBytes(ticket+0xD0,1,false)), b(readBytes(ticket+0xD1,1,false)), b(readBytes(ticket+0xD2,1,false)), b(readBytes(ticket+0xE0,1,false)))
    if data and data ~= 0 then
      out[#out+1] = string.format('票数据: price=%s hardness=%s baseLuck=%s scratchRatio=%s xpNeeded=%s catalog=%s', tostring(readDouble(data+0x20)), tostring(readInteger(data+0x28,4)), tostring(readInteger(data+0x2C,4)), tostring(readFloat(data+0x30)), tostring(readInteger(data+0x34,4)), tostring(readInteger(data+0x40,4)))
    end
  else
    out[#out+1] = '当前票: nil'
  end
else
  out[#out+1] = '刮卡: PlayerScratching 未找到'
end

local sjm = findInstance('SuperJackpotManager')
if sjm and sjm ~= 0 then
  local superTicket = readQword(sjm + 0xC0)
  local active = readBytes(sjm + 0xC8, 1, false)
  out[#out+1] = string.format('超级头奖: manager=%s isActive=%s superTicket=%s', hx(sjm), b(active), hx(superTicket))
  if superTicket and superTicket ~= 0 then
    local data = readQword(superTicket + 0xC8)
    local id = data and rstr(readQword(data + 0x10)) or nil
    out[#out+1] = string.format('超级票: data=%s id=%s allScratched=%s isJackpot=%s', hx(data), tostring(id), b(readBytes(superTicket+0xD1,1,false)), b(readBytes(superTicket+0xD2,1,false)))
  end
else
  out[#out+1] = '超级头奖: manager 未找到'
end

return table.concat(out, '\n')
