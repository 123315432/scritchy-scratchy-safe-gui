-- Patch SuperLucky perk stack from 1 to 2
-- Run in CE Lua console (Table > Show Cheat Table Lua Script, or Ctrl+Alt+L)
-- PerkManager singleton must be at 0x16E599615C0 (current session)

openProcess('ScritchyScratchy.exe')

local pm = 0x16E599615C0
local dict = readQword(pm + 0x28)
local entries = readQword(dict + 0x18)
local count = readInteger(dict + 0x20)

print('activePerks count = '..count)
print('entries array = 0x'..string.format('%X', entries))

-- Try different entry layouts
local layouts = {
  {name='layout_A (size=0x18, key@+0x08)', size=0x18, key_off=0x08, val_off=0x10},
  {name='layout_B (size=0x18, key@+0x0C)', size=0x18, key_off=0x0C, val_off=0x10},
  {name='layout_C (size=0x20, key@+0x08)', size=0x20, key_off=0x08, val_off=0x10},
  {name='layout_D (size=0x20, key@+0x0C)', size=0x20, key_off=0x0C, val_off=0x10},
}

for _, layout in ipairs(layouts) do
  print('\nTrying '..layout.name..'...')
  for i = 0, count-1 do
    local base = entries + 0x20 + i * layout.size
    local key = readInteger(base + layout.key_off)
    if key == 45 then
      local tuple = readQword(base + layout.val_off)
      if tuple ~= nil and tuple ~= 0 then
        local item2 = readInteger(tuple + 0x18)
        print(string.format('  FOUND key=45 at entry %d, tuple=0x%X, stack=%d', i, tuple, item2))
        if item2 == 1 then
          writeInteger(tuple + 0x18, 2)
          local verify = readInteger(tuple + 0x18)
          print('  WRITTEN stack=2, verify='..verify)
          if verify == 2 then
            print('  SUCCESS! SuperLucky stack patched to 2')
            return
          end
        elseif item2 == 2 then
          print('  Already patched to 2!')
          return
        else
          print('  Unexpected stack value: '..item2..', trying Tuple+0x10 instead...')
          local alt = readInteger(tuple + 0x10)
          print('  Tuple+0x10 = '..alt)
        end
      end
    end
  end
end

print('\nNot found with any layout. Dumping first 5 entries raw...')
for i = 0, 4 do
  local base = entries + 0x20 + i * 0x20
  local raw = ''
  for j = 0, 0x1F do
    raw = raw .. string.format('%02X ', readBytes(base + j, 1))
  end
  print(string.format('  entry[%d] @ 0x%X: %s', i, base, raw))
end
