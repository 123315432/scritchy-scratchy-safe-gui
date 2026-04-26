-- perk_all_v2.lua - direct executeMethod, no stubs
openProcess('ScritchyScratchy.exe')
local base = getAddressSafe('GameAssembly.dll')
if not base or base == 0 then return 'ERR: GameAssembly.dll not found' end

-- Init IL2CPP mono bridge
local monoOk = false
for _ = 1, 3 do
  local ok = pcall(LaunchMonoDataCollector)
  if ok then
    monoOk = true
    break
  end
  sleep(200)
end

local ACTIVATE_RVA = 0x4AE080

-- Find PerkManager instance via mono
local mgr = nil
local monoErr = 'mono not init'

if monoOk then
  local cls = mono_findClass('', 'PerkManager')
  if cls then
    local list = mono_class_findInstancesOfClassListOnly(nil, cls) or {}
    for _, inst in ipairs(list) do
      if inst and inst ~= 0 then
        mgr = inst
        break
      end
    end
    if not mgr then
      -- Try static field _instance or _current
      local saddr = mono_class_getStaticFieldAddress(0, cls)
      if saddr and saddr ~= 0 then
        local fields = mono_class_enumFields(cls, true) or {}
        for _, f in ipairs(fields) do
          if f.name:find('instance') or f.name:find('current') or f.name:find('Instance') then
            local ptr = readQword(saddr + f.offset)
            if ptr and ptr ~= 0 then mgr = ptr break end
          end
        end
      end
    end
    monoErr = mgr and 'found' or 'no instance'
  else
    monoErr = 'PerkManager class not found'
  end
end

if not mgr or mgr == 0 then
  return 'ERR: PerkManager instance not found: ' .. monoErr
end

local ok_count = 0
local fail_list = {}

-- Activate important perks first
local important = {19, 36}  -- HandsOff, FullyAutomated
for _, perkId in ipairs(important) do
  local ok = pcall(function()
    executeMethod(0, 3000, base + ACTIVATE_RVA, mgr, {type=1, value=perkId}, {type=1, value=1}, {type=0, value=0})
  end)
  if ok then ok_count = ok_count + 1 else fail_list[#fail_list+1] = perkId end
end

-- Activate all 0..50
for i = 0, 50 do
  -- skip already done
  if i ~= 19 and i ~= 36 then
    local ok = pcall(function()
      executeMethod(0, 3000, base + ACTIVATE_RVA, mgr, {type=1, value=i}, {type=1, value=1}, {type=0, value=0})
    end)
    if ok then ok_count = ok_count + 1 else fail_list[#fail_list+1] = i end
  end
end

return string.format('OK mgr=0x%X activated=%d failed=%d fails=%s',
  mgr, ok_count, #fail_list, table.concat(fail_list, ','))
