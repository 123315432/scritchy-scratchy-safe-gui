-- dump_pointer_chains.lua - read-only Scritchy Scratchy pointer chain resolver
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end
local function hx(v) return v and string.format('0x%X', v) or 'nil' end
local function readMovRipSlot(callsite)
  local b = readBytes(callsite, 7, true)
  if not b or #b < 7 or b[1] ~= 0x48 or b[2] ~= 0x8B or b[3] ~= 0x0D then
    return nil, 'bad_mov_rip at ' .. hx(callsite)
  end
  local disp = b[4] | (b[5] << 8) | (b[6] << 16) | (b[7] << 24)
  if disp >= 0x80000000 then disp = disp - 0x100000000 end
  return callsite + 7 + disp, nil
end
local function currentFromCallsite(name, rva)
  local callsite = base + rva
  local slot, err = readMovRipSlot(callsite)
  if not slot then return {name=name, err=err} end
  local genericCtx = readQword(slot)
  local ok, ptr = pcall(function()
    return executeMethod(0, 5000, base + 0xB812D0, genericCtx)
  end)
  if not ok then return {name=name, callsite=callsite, slot=slot, genericCtx=genericCtx, err=tostring(ptr)} end
  return {name=name, callsite=callsite, slot=slot, genericCtx=genericCtx, ptr=ptr}
end
local function getSaveData()
  local ok, ptr = pcall(function() return executeMethod(0, 5000, base + 0x4D02F0, {type=0, value=0}) end)
  if ok and ptr and ptr ~= 0 then return ptr, 'method' end
  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', 'SaveData')
  if cls then
    local saddr = mono_class_getStaticFieldAddress(0, cls)
    for _, f in ipairs(mono_class_enumFields(cls, true) or {}) do
      if f.name == '_current' or f.name == 'current' then
        local p = readQword(saddr + f.offset)
        if p and p ~= 0 then return p, 'mono_static' end
      end
    end
  end
  return nil, 'not_found'
end
local function monoFirst(name)
  pcall(LaunchMonoDataCollector)
  local cls = mono_findClass and mono_findClass('', name)
  if not cls then return nil, 0 end
  local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}
  return list[1], #list
end
local savedata, saveSource = getSaveData()
local layerOne = savedata and readQword(savedata + 0x30) or nil
local roots = {
  currentFromCallsite('PerkManager', 0x4AE723),
  currentFromCallsite('DebugTools', 0x49361D),
}
local monoNames = {'SuperJackpotManager','TicketShop','PrestigeManager','PlayerScratching','PlayerWallet','TicketProgressionManager'}
local out = {}
out[#out+1] = 'GameAssembly=' .. hx(base)
out[#out+1] = 'SaveData=' .. hx(savedata) .. ' source=' .. tostring(saveSource)
out[#out+1] = 'LayerOne=[SaveData+30]=' .. hx(layerOne)
if savedata then
  out[#out+1] = string.format('SaveData fields prestige=%s currency=%s act=%s tokens=%s',
    tostring(readInteger(savedata+0x38,4)), tostring(readInteger(savedata+0x3C,4)),
    tostring(readInteger(savedata+0x40,4)), tostring(readDouble(savedata+0xC8)))
end
if layerOne then
  out[#out+1] = 'LayerOne ptrs ticketProgressionDict=' .. hx(readQword(layerOne+0x20)) ..
    ' jackpotsGotten=' .. hx(readQword(layerOne+0x40)) ..
    ' superJackpotsGotten=' .. hx(readQword(layerOne+0x48)) ..
    ' claimedItems=' .. hx(readQword(layerOne+0x60))
end
for _, r in ipairs(roots) do
  out[#out+1] = string.format('%s callsite=%s slot=%s genericCtx=%s ptr=%s err=%s',
    r.name, hx(r.callsite), hx(r.slot), hx(r.genericCtx), hx(r.ptr), tostring(r.err))
  if r.name == 'PerkManager' and r.ptr and r.ptr ~= 0 then
    out[#out+1] = '  activePerks=[+28]=' .. hx(readQword(r.ptr+0x28)) .. ' symbols=[+30]=' .. hx(readQword(r.ptr+0x30))
  end
end
for _, name in ipairs(monoNames) do
  local ptr, count = monoFirst(name)
  out[#out+1] = string.format('%s mono count=%d ptr=%s', name, count, hx(ptr))
end
return table.concat(out, '\n')
