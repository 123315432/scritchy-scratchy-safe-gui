-- ScritchyScratchy RNG control
--
-- Usage examples:
--   SCRITCHY_RNG_MODE = 'max_weight'
--   dofile([[<repo>\ce_scripts\rng_control.lua]])
--
--   SCRITCHY_RNG_MODE = 'force_index'
--   SCRITCHY_FORCE_INDEX = 0
--   dofile([[<repo>\ce_scripts\rng_control.lua]])
--
--   SCRITCHY_RNG_MODE = 'force_symbol_type'
--   SCRITCHY_FORCE_SYMBOL_TYPE = 2   -- Jackpot
--   dofile([[<repo>\ce_scripts\rng_control.lua]])
--
--   SCRITCHY_RNG_MODE = 'force_symbol_type'
--   SCRITCHY_FORCE_SYMBOL_TYPE = 3   -- SuperJackpot
--   SCRITCHY_FORCE_RANDOM_VALUE = 0.0
--   dofile([[<repo>\ce_scripts\rng_control.lua]])
--
--   SCRITCHY_RNG_UNINSTALL = true
--   dofile([[<repo>\ce_scripts\rng_control.lua]])
--
-- SymbolType: Bad=-1, Dud=0, Small=1, Jackpot=2, SuperJackpot=3, Mult=4, SelfDestruct=5

local GAME_EXE = 'ScritchyScratchy.exe'
local MODULE_NAME = 'GameAssembly.dll'

local RNG_PICK_CALLSITE_RVA = 0x4E6291
local RNG_PICK_HELPER_RVA = 0x49AAC0
local RNG_VALUE_CALLSITE_RVA = 0x4E65EC
local RNG_VALUE_FUNC_RVA = 0x2619240

local RNG_PICK_ORIG_BYTES = {0xE8, 0x2A, 0x48, 0xFB, 0xFF}
local RNG_VALUE_ORIG_BYTES = {0xE8, 0x4F, 0x2C, 0x13, 0x02}

local MODE_MAP = {
  pass_through = 0,
  original = 0,
  force_index = 1,
  max_weight = 2,
  force_symbol_type = 3,
}

local DEFAULT_MODE = 'max_weight'
local DEFAULT_FORCE_INDEX = 0
local DEFAULT_FORCE_SYMBOL_TYPE = 2

local function log(msg)
  print('[rng_control] ' .. msg)
end

local function hex(v)
  if v == nil then
    return 'nil'
  end
  return string.format('0x%X', v)
end

local function bytesToHex(bytes)
  if not bytes then
    return 'nil'
  end

  local t = {}
  for i = 1, #bytes do
    t[#t + 1] = string.format('%02X', bytes[i])
  end
  return table.concat(t, ' ')
end

local function readBytesSafe(addr, count)
  return readBytes(addr, count, true)
end

local function ensureTarget()
  pcall(openProcess, GAME_EXE)
  local base = getAddressSafe(MODULE_NAME)
  if not base or base == 0 then
    error(MODULE_NAME .. ' is not loaded. Attach to ' .. GAME_EXE .. ' first.')
  end
  return base
end

local function symbolAddr(name)
  local addr = getAddressSafe(name)
  if not addr or addr == 0 then
    return nil
  end
  return addr
end

local function isHookInstalled()
  return symbolAddr('ss_rng_mode') ~= nil
end

local function isPickHookPatched(base)
  local bytes = readBytesSafe(base + RNG_PICK_CALLSITE_RVA, 1)
  return bytes and bytes[1] == 0xE9
end

local function isValueHookPatched(base)
  local bytes = readBytesSafe(base + RNG_VALUE_CALLSITE_RVA, 1)
  return bytes and bytes[1] == 0xE9
end

local function getModeId(rawMode)
  if type(rawMode) == 'number' then
    return rawMode
  end

  local mode = tostring(rawMode or DEFAULT_MODE)
  local mapped = MODE_MAP[mode]
  if mapped == nil then
    error('Unsupported SCRITCHY_RNG_MODE: ' .. mode)
  end
  return mapped
end

local function installHook()
  local aa = [[
define(ss_rng_pick_callsite,GameAssembly.dll+4E6291)
define(ss_rng_pick_helper,GameAssembly.dll+49AAC0)
define(ss_rng_value_callsite,GameAssembly.dll+4E65EC)
define(ss_rng_value_func,GameAssembly.dll+2619240)

assert(ss_rng_pick_callsite,E8 2A 48 FB FF)
assert(ss_rng_pick_helper,48 89 4C 24 08 53)
assert(ss_rng_value_callsite,E8 4F 2C 13 02)

alloc(ss_rng_newmem,2048,ss_rng_pick_callsite)
alloc(ss_rng_cfg,256,ss_rng_pick_callsite)

label(ss_rng_pick_return)
label(ss_rng_value_return)
label(ss_rng_pick_newmem)
label(ss_rng_value_newmem)
label(ss_rng_callorig)
label(ss_rng_forceindex)
label(ss_rng_forceindex_nonneg)
label(ss_rng_forceindex_done)
label(ss_rng_maxweight)
label(ss_rng_maxweight_loop)
label(ss_rng_maxweight_update)
label(ss_rng_maxweight_done)
label(ss_rng_forcetype)
label(ss_rng_forcetype_loop)
label(ss_rng_forcetype_next)
label(ss_rng_forcetype_found)
label(ss_rng_done)
label(ss_rng_value_orig)
label(ss_rng_value_forced)

label(ss_rng_mode)
label(ss_rng_force_index)
label(ss_rng_force_symbol_type)
label(ss_rng_last_index)
label(ss_rng_last_reason)
label(ss_rng_hit_count)
label(ss_rng_force_random_value_enabled)
label(ss_rng_forced_random_value)
label(ss_rng_last_random_value)
label(ss_rng_last_chance_list)
label(ss_rng_last_symbol_list)
label(ss_rng_last_ticket)

registersymbol(ss_rng_pick_callsite)
registersymbol(ss_rng_value_callsite)
registersymbol(ss_rng_mode)
registersymbol(ss_rng_force_index)
registersymbol(ss_rng_force_symbol_type)
registersymbol(ss_rng_last_index)
registersymbol(ss_rng_last_reason)
registersymbol(ss_rng_hit_count)
registersymbol(ss_rng_force_random_value_enabled)
registersymbol(ss_rng_forced_random_value)
registersymbol(ss_rng_last_random_value)
registersymbol(ss_rng_last_chance_list)
registersymbol(ss_rng_last_symbol_list)
registersymbol(ss_rng_last_ticket)

ss_rng_cfg:
ss_rng_mode:
dd 0
ss_rng_force_index:
dd 0
ss_rng_force_symbol_type:
dd 2
ss_rng_last_index:
dd -1
ss_rng_last_reason:
dd 0
ss_rng_hit_count:
dd 0
ss_rng_force_random_value_enabled:
dd 0
ss_rng_forced_random_value:
dd 0
ss_rng_last_random_value:
dd 0
align 8 CC
ss_rng_last_chance_list:
dq 0
ss_rng_last_symbol_list:
dq 0
ss_rng_last_ticket:
dq 0

ss_rng_pick_newmem:
  inc dword ptr [ss_rng_hit_count]
  mov [ss_rng_last_chance_list],rcx
  mov [ss_rng_last_symbol_list],rdi
  mov [ss_rng_last_ticket],rbx
  mov dword ptr [ss_rng_last_reason],0
  mov r11d,[ss_rng_mode]
  cmp r11d,0
  je ss_rng_callorig
  cmp r11d,1
  je ss_rng_forceindex
  cmp r11d,2
  je ss_rng_maxweight
  cmp r11d,3
  je ss_rng_forcetype

ss_rng_callorig:
  xor edx,edx
  call ss_rng_pick_helper
  mov [ss_rng_last_index],eax
  jmp ss_rng_done

ss_rng_forceindex:
  test rcx,rcx
  je ss_rng_callorig
  mov r10d,[rcx+18]
  test r10d,r10d
  jle ss_rng_callorig
  mov edx,[ss_rng_force_index]
  test edx,edx
  jns ss_rng_forceindex_nonneg
  xor edx,edx
ss_rng_forceindex_nonneg:
  cmp edx,r10d
  jl ss_rng_forceindex_done
  mov edx,r10d
  dec edx
ss_rng_forceindex_done:
  mov eax,edx
  mov [ss_rng_last_index],eax
  mov dword ptr [ss_rng_last_reason],1
  jmp ss_rng_done

ss_rng_maxweight:
  test rcx,rcx
  je ss_rng_callorig
  mov r10,[rcx+10]
  mov r11d,[rcx+18]
  test r10,r10
  je ss_rng_callorig
  cmp r11d,1
  jl ss_rng_callorig
  xor edx,edx
  movss xmm0,[r10+20]
  mov ecx,1
ss_rng_maxweight_loop:
  cmp ecx,r11d
  jge ss_rng_maxweight_done
  movss xmm1,[r10+rcx*4+20]
  comiss xmm1,xmm0
  ja ss_rng_maxweight_update
ss_rng_maxweight_next:
  inc ecx
  jmp ss_rng_maxweight_loop
ss_rng_maxweight_update:
  movaps xmm0,xmm1
  mov edx,ecx
  jmp ss_rng_maxweight_next
ss_rng_maxweight_done:
  mov eax,edx
  mov [ss_rng_last_index],eax
  mov dword ptr [ss_rng_last_reason],2
  jmp ss_rng_done

ss_rng_forcetype:
  test rdi,rdi
  je ss_rng_callorig
  mov r10,[rdi+10]
  mov r11d,[rdi+18]
  test r10,r10
  je ss_rng_callorig
  cmp r11d,1
  jl ss_rng_callorig
  xor ecx,ecx
  mov edx,[ss_rng_force_symbol_type]
ss_rng_forcetype_loop:
  cmp ecx,r11d
  jge ss_rng_callorig
  mov r8,[r10+rcx*8+20]
  test r8,r8
  je ss_rng_forcetype_next
  cmp dword ptr [r8+38],edx
  je ss_rng_forcetype_found
ss_rng_forcetype_next:
  inc ecx
  jmp ss_rng_forcetype_loop
ss_rng_forcetype_found:
  mov eax,ecx
  mov [ss_rng_last_index],eax
  mov dword ptr [ss_rng_last_reason],3
  jmp ss_rng_done

ss_rng_done:
  jmp ss_rng_pick_return

ss_rng_value_newmem:
  cmp dword ptr [ss_rng_force_random_value_enabled],0
  jne ss_rng_value_forced
ss_rng_value_orig:
  call ss_rng_value_func
  movss [ss_rng_last_random_value],xmm0
  jmp ss_rng_value_return
ss_rng_value_forced:
  movss xmm0,[ss_rng_forced_random_value]
  movss [ss_rng_last_random_value],xmm0
  jmp ss_rng_value_return

ss_rng_pick_callsite:
  jmp ss_rng_pick_newmem
ss_rng_pick_return:

ss_rng_value_callsite:
  jmp ss_rng_value_newmem
ss_rng_value_return:
]]

  local ok, err = autoAssemble(aa)
  if not ok then
    error('install autoAssemble failed: ' .. tostring(err))
  end
end

local function uninstallHook(base)
  local pickAddr = base + RNG_PICK_CALLSITE_RVA
  local valueAddr = base + RNG_VALUE_CALLSITE_RVA

  if not isPickHookPatched(base) and not isValueHookPatched(base) and not isHookInstalled() then
    return 'not_installed'
  end

  local disable = [[
define(ss_rng_pick_callsite,GameAssembly.dll+4E6291)
define(ss_rng_value_callsite,GameAssembly.dll+4E65EC)

ss_rng_pick_callsite:
db E8 2A 48 FB FF

ss_rng_value_callsite:
db E8 4F 2C 13 02

unregistersymbol(ss_rng_pick_callsite)
unregistersymbol(ss_rng_value_callsite)
unregistersymbol(ss_rng_mode)
unregistersymbol(ss_rng_force_index)
unregistersymbol(ss_rng_force_symbol_type)
unregistersymbol(ss_rng_last_index)
unregistersymbol(ss_rng_last_reason)
unregistersymbol(ss_rng_hit_count)
unregistersymbol(ss_rng_force_random_value_enabled)
unregistersymbol(ss_rng_forced_random_value)
unregistersymbol(ss_rng_last_random_value)
unregistersymbol(ss_rng_last_chance_list)
unregistersymbol(ss_rng_last_symbol_list)
unregistersymbol(ss_rng_last_ticket)

dealloc(ss_rng_newmem)
dealloc(ss_rng_cfg)
]]

  local ok, err = autoAssemble(disable)
  if not ok then
    error('uninstall autoAssemble failed: ' .. tostring(err)
      .. ' pick=' .. bytesToHex(readBytesSafe(pickAddr, 8))
      .. ' value=' .. bytesToHex(readBytesSafe(valueAddr, 5)))
  end

  return 'uninstalled'
end

local function writeConfig(modeId, forceIndex, forceSymbolType, randomValueEnabled, forcedRandomValue)
  local modeAddr = assert(symbolAddr('ss_rng_mode'), 'ss_rng_mode missing after install')
  local indexAddr = assert(symbolAddr('ss_rng_force_index'), 'ss_rng_force_index missing after install')
  local typeAddr = assert(symbolAddr('ss_rng_force_symbol_type'), 'ss_rng_force_symbol_type missing after install')
  local randEnableAddr = assert(symbolAddr('ss_rng_force_random_value_enabled'), 'ss_rng_force_random_value_enabled missing after install')
  local randValueAddr = assert(symbolAddr('ss_rng_forced_random_value'), 'ss_rng_forced_random_value missing after install')

  writeInteger(modeAddr, modeId)
  writeInteger(indexAddr, forceIndex)
  writeInteger(typeAddr, forceSymbolType)
  writeInteger(randEnableAddr, randomValueEnabled and 1 or 0)
  writeFloat(randValueAddr, forcedRandomValue or 0.0)
end

local function readConfigSnapshot(base)
  local snapshot = {}
  local names = {
    'ss_rng_mode',
    'ss_rng_force_index',
    'ss_rng_force_symbol_type',
    'ss_rng_last_index',
    'ss_rng_last_reason',
    'ss_rng_hit_count',
    'ss_rng_force_random_value_enabled',
    'ss_rng_forced_random_value',
    'ss_rng_last_random_value',
    'ss_rng_last_chance_list',
    'ss_rng_last_symbol_list',
    'ss_rng_last_ticket',
  }

  for _, name in ipairs(names) do
    local addr = symbolAddr(name)
    if addr then
      if name == 'ss_rng_forced_random_value' or name == 'ss_rng_last_random_value' then
        snapshot[name] = tostring(readFloat(addr))
      elseif name == 'ss_rng_last_chance_list' or name == 'ss_rng_last_symbol_list' or name == 'ss_rng_last_ticket' then
        snapshot[name] = hex(readQword(addr))
      else
        snapshot[name] = tostring(readInteger(addr))
      end
    else
      snapshot[name] = 'nil'
    end
  end

  snapshot.pick_bytes = bytesToHex(readBytesSafe(base + RNG_PICK_CALLSITE_RVA, 8))
  snapshot.value_bytes = bytesToHex(readBytesSafe(base + RNG_VALUE_CALLSITE_RVA, 5))
  return snapshot
end

local function snapshotToString(snapshot)
  local parts = {}
  local order = {
    'ss_rng_mode',
    'ss_rng_force_index',
    'ss_rng_force_symbol_type',
    'ss_rng_last_index',
    'ss_rng_last_reason',
    'ss_rng_hit_count',
    'ss_rng_force_random_value_enabled',
    'ss_rng_forced_random_value',
    'ss_rng_last_random_value',
    'ss_rng_last_chance_list',
    'ss_rng_last_symbol_list',
    'ss_rng_last_ticket',
    'pick_bytes',
    'value_bytes',
  }

  for _, key in ipairs(order) do
    parts[#parts + 1] = key .. '=' .. tostring(snapshot[key])
  end
  return table.concat(parts, ' ')
end

local base = ensureTarget()

if rawget(_G, 'SCRITCHY_RNG_UNINSTALL') then
  local result = uninstallHook(base)
  log(result .. ' pick=' .. bytesToHex(readBytesSafe(base + RNG_PICK_CALLSITE_RVA, 8))
    .. ' value=' .. bytesToHex(readBytesSafe(base + RNG_VALUE_CALLSITE_RVA, 5)))
  return result
end

if not isHookInstalled() then
  installHook()
end

local modeId = getModeId(rawget(_G, 'SCRITCHY_RNG_MODE'))
local forceIndex = tonumber(rawget(_G, 'SCRITCHY_FORCE_INDEX')) or DEFAULT_FORCE_INDEX
local forceSymbolType = tonumber(rawget(_G, 'SCRITCHY_FORCE_SYMBOL_TYPE')) or DEFAULT_FORCE_SYMBOL_TYPE
local forceRandomValue = rawget(_G, 'SCRITCHY_FORCE_RANDOM_VALUE')
local randomValueEnabled = forceRandomValue ~= nil
local forcedRandomValue = tonumber(forceRandomValue) or 0.0

writeConfig(modeId, forceIndex, forceSymbolType, randomValueEnabled, forcedRandomValue)

local snap = readConfigSnapshot(base)
local summary = string.format(
  'installed=true base=%s pick_callsite=%s value_callsite=%s mode=%d force_index=%d force_symbol_type=%d random_value_enabled=%s random_value=%s %s',
  hex(base),
  hex(base + RNG_PICK_CALLSITE_RVA),
  hex(base + RNG_VALUE_CALLSITE_RVA),
  modeId,
  forceIndex,
  forceSymbolType,
  tostring(randomValueEnabled),
  tostring(forcedRandomValue),
  snapshotToString(snap)
)

log(summary)
return summary
