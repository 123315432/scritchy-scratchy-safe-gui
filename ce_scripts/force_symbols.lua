-- force_symbols.lua
-- Deterministic per-slot symbol forcing for Scritchy Scratchy
--
-- Usage:
--   1. Attach CE to ScritchyScratchy.exe
--   2. Run this file once in CE Lua Engine:
--        dofile([[<repo>\ce_scripts\force_symbols.lua]])
--   3. Enable forcing:
--        force_symbols_enable(0, SYMBOL_TYPE.SuperJackpot)
--   4. Generate / open a fresh ticket
--   5. Disable / uninstall when done:
--        force_symbols_disable()
--        force_symbols_uninstall()
--
-- Notes:
--   - slot index is 0-based
--   - replacement SymbolData is searched from current ticket.Data.symbols
--   - if the current ticket has no symbol of the requested SymbolType, original data is kept
--   - hook point is SymbolSlot.UpdateData, because GetSymbolChances is whole-ticket scope

local GAME_EXE = 'ScritchyScratchy.exe'
local MODULE_NAME = 'GameAssembly.dll'

local UPDATE_DATA_RVA = 0x4E1490
local UPDATE_DATA_ASSERT = '48 89 5C 24 10 48 89 74 24 18 57 48 83 EC 20'

SYMBOL_TYPE = {
  Bad = -1,
  Dud = 0,
  Small = 1,
  Jackpot = 2,
  SuperJackpot = 3,
  Mult = 4,
  SelfDestruct = 5,
}

local state = {
  installed = false,
  enabled = false,
  slot_index = 0,
  symbol_type = SYMBOL_TYPE.SuperJackpot,
}

local function log(msg)
  print('[force_symbols] ' .. msg)
end

local function hex(v)
  if v == nil then
    return 'nil'
  end
  return string.format('0x%X', v)
end

local function ensureTarget()
  pcall(openProcess, GAME_EXE)
  local base = getAddressSafe(MODULE_NAME)
  if not base or base == 0 then
    return nil, MODULE_NAME .. ' is not loaded. Attach to ' .. GAME_EXE .. ' first.'
  end
  return base
end

local function getSymbol(symbol)
  local v = getAddressSafe(symbol)
  if not v or v == 0 then
    return nil
  end
  return v
end

local function buildScript()
  return ([[
alloc(ss_force_symbols_mem,2048,%s+%X)
registersymbol(ss_force_symbols_mem)
registersymbol(ss_force_symbols_enabled)
registersymbol(ss_force_symbols_slot)
registersymbol(ss_force_symbols_type)
registersymbol(ss_force_symbols_hook)
registersymbol(ss_force_symbols_return)

label(ss_force_symbols_enabled)
label(ss_force_symbols_slot)
label(ss_force_symbols_type)
label(ss_force_symbols_code)
label(ss_force_symbols_hook)
label(ss_force_symbols_return)
label(ss_scan_slots)
label(ss_slot_found)
label(ss_scan_symbols)
label(ss_apply_symbol)
label(ss_skip_force)
label(ss_resume_original)
label(ss_resume)

ss_force_symbols_mem:
ss_force_symbols_enabled:
  dd 0
ss_force_symbols_slot:
  dd 0
ss_force_symbols_type:
  dd 3
  dd 0
ss_force_symbols_code:
  mov [rsp+08],r8
  mov [rsp+20],rdx
  cmp dword ptr [ss_force_symbols_enabled],0
  je ss_resume_original
  test rcx,rcx
  je ss_resume_original
  test r8,r8
  je ss_resume_original

  mov rax,[r8+98]
  test rax,rax
  je ss_resume_original
  mov r10,[rax+10]
  test r10,r10
  je ss_resume_original
  xor r9d,r9d

ss_scan_slots:
  cmp r9d,[rax+18]
  jge ss_resume_original
  mov r11,[r10+20+r9*8]
  cmp r11,rcx
  je ss_slot_found
  inc r9d
  jmp ss_scan_slots

ss_slot_found:
  cmp r9d,[ss_force_symbols_slot]
  jne ss_resume_original
  mov rax,[r8+C8]
  test rax,rax
  je ss_resume_original
  mov rax,[rax+48]
  test rax,rax
  je ss_resume_original
  mov r10,[rax+10]
  test r10,r10
  je ss_resume_original
  xor r9d,r9d

ss_scan_symbols:
  cmp r9d,[rax+18]
  jge ss_resume_original
  mov r11,[r10+20+r9*8]
  test r11,r11
  je ss_skip_force
  mov edx,[ss_force_symbols_type]
  cmp dword ptr [r11+38],edx
  je ss_apply_symbol

ss_skip_force:
  inc r9d
  jmp ss_scan_symbols

ss_apply_symbol:
  mov rdx,r11
  jmp ss_resume

ss_resume_original:
  mov rdx,[rsp+20]

ss_resume:
  mov r8,[rsp+08]
  mov [rsp+10],rbx
  mov [rsp+18],rsi
  push rdi
  sub rsp,20
  jmp ss_force_symbols_return

ss_force_symbols_hook:
  jmp ss_force_symbols_code
  nop
  nop
  nop

ss_force_symbols_return:
  jmp %s+%X

%s+%X:
  jmp ss_force_symbols_hook
  nop
  nop
  nop

assert(%s+%X,%s)
]]):format(
    MODULE_NAME, UPDATE_DATA_RVA,
    MODULE_NAME, UPDATE_DATA_RVA + 0x0F,
    MODULE_NAME, UPDATE_DATA_RVA,
    MODULE_NAME, UPDATE_DATA_RVA,
    UPDATE_DATA_ASSERT
  )
end

local function install()
  if state.installed then
    return true
  end

  local base, err = ensureTarget()
  if not base then
    return nil, err
  end

  local ok, aaErr = autoAssemble(buildScript())
  if not ok then
    return nil, aaErr
  end

  state.installed = true
  state.base = base
  return true
end

local function writeConfig()
  local enabled = getSymbol('ss_force_symbols_enabled')
  local slot = getSymbol('ss_force_symbols_slot')
  local symType = getSymbol('ss_force_symbols_type')
  if not enabled or not slot or not symType then
    return nil, 'force symbol config symbols are missing'
  end

  writeInteger(enabled, state.enabled and 1 or 0)
  writeInteger(slot, state.slot_index)
  writeInteger(symType, state.symbol_type)
  return true
end

function force_symbols_enable(slotIndex, symbolType)
  local ok, err = install()
  if not ok then
    log('ERROR: install failed: ' .. tostring(err))
    return false
  end

  if type(slotIndex) ~= 'number' or slotIndex < 0 then
    log('ERROR: slotIndex must be a non-negative integer')
    return false
  end

  if type(symbolType) ~= 'number' then
    log('ERROR: symbolType must be a number from SYMBOL_TYPE')
    return false
  end

  state.slot_index = math.floor(slotIndex)
  state.symbol_type = math.floor(symbolType)
  state.enabled = true

  local wrote, writeErr = writeConfig()
  if not wrote then
    log('ERROR: failed to write config: ' .. tostring(writeErr))
    return false
  end

  log(string.format('enabled slot=%d symbolType=%d base=%s', state.slot_index, state.symbol_type, hex(state.base)))
  return true
end

function force_symbols_disable()
  state.enabled = false
  local wrote, err = writeConfig()
  if not wrote then
    log('WARN: disable config write failed: ' .. tostring(err))
  end
  log('disabled runtime forcing')
end

function force_symbols_status()
  log(string.format(
    'status installed=%s enabled=%s slot=%d symbolType=%d base=%s',
    tostring(state.installed),
    tostring(state.enabled),
    tonumber(state.slot_index or -1),
    tonumber(state.symbol_type or -999),
    hex(state.base)
  ))
end

function force_symbols_uninstall()
  state.enabled = false

  if state.installed then
    local ok, err = autoAssemble(([[
%s+%X:
  db %s
unregistersymbol(ss_force_symbols_mem)
unregistersymbol(ss_force_symbols_enabled)
unregistersymbol(ss_force_symbols_slot)
unregistersymbol(ss_force_symbols_type)
unregistersymbol(ss_force_symbols_hook)
unregistersymbol(ss_force_symbols_return)
dealloc(ss_force_symbols_mem)
]]):format(MODULE_NAME, UPDATE_DATA_RVA, UPDATE_DATA_ASSERT))
    if not ok then
      log('WARN: uninstall failed: ' .. tostring(err))
    end
  end

  state.installed = false
  state.base = nil
  log('hook uninstalled')
end

log('loaded; use force_symbols_enable(slotIndex, SYMBOL_TYPE.SuperJackpot)')
