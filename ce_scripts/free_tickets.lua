-- ScritchyScratchy: free tickets / zero TicketShop price
-- Static basis:
--   PlayerWallet.CanAfford    RVA 0x4C28E0
--   PlayerWallet.TrySubtract  RVA 0x4C2D00
--   ShopPanel.CalculatePrice  RVA 0x4F0220
-- Optional experimental:
--   LoanPanel.GetTicketPriceMult RVA 0x4A7630
--
-- Strategy:
--   1) Make PlayerWallet affordability / subtraction always succeed.
--   2) Make TicketShop / UpgradeShop panel price calculation return 0.0.
--   3) Optional: make ticket price multiplier return 0.0.
--
-- Scope note:
--   Wallet patches affect every spend path routed through PlayerWallet,
--   not just tickets. Run this only when you want broad free purchases.
--
-- Usage:
--   SCRITCHY_FREE_TICKETS_MODE = 'enable'  -> enable patches
--   SCRITCHY_FREE_TICKETS_MODE = 'disable' -> restore patches
--   unset/default                           -> dry-run only

openProcess('ScritchyScratchy.exe')

local EXPERIMENTAL_ZERO_TICKET_PRICE_MULT = false

local function bytesToHex(bytes)
  if not bytes then
    return 'READ_FAIL'
  end

  local out = {}
  for i = 1, #bytes do
    out[#out + 1] = string.format('%02X', bytes[i])
  end
  return table.concat(out, ' ')
end

local function readBytesSafe(addr, count)
  return readBytes(addr, count, true)
end

local function getModuleBase()
  local base = getAddressSafe('GameAssembly.dll')
  if not base then
    error('GameAssembly.dll not found. Start the game first.')
  end
  return base
end

local function makePatch(name, rva, onBytes)
  return {
    name = name,
    rva = rva,
    onBytes = onBytes,
    size = #onBytes,
  }
end

local function restorePatch(p)
  if not p.original then
    return string.format('%s=NO_ORIG', p.name)
  end
  writeBytes(p.addr, table.unpack(p.original))
  return string.format('%s=RESTORED[%s]', p.name, bytesToHex(readBytesSafe(p.addr, p.size)))
end

local function bytesEqual(left, right)
  if not left or not right or #left ~= #right then
    return false
  end
  for i = 1, #left do
    if left[i] ~= right[i] then
      return false
    end
  end
  return true
end

local function enablePatch(p)
  p.original = readBytesSafe(p.addr, p.size)
  if not p.original then
    return string.format('%s=READ_FAIL', p.name)
  end

  writeBytes(p.addr, table.unpack(p.onBytes))
  local verify = readBytesSafe(p.addr, p.size)
  return string.format('%s=PATCHED[%s] orig=[%s]', p.name, bytesToHex(verify), bytesToHex(p.original))
end

local base = getModuleBase()
local openedPid = getOpenedProcessID and getOpenedProcessID() or 0
local patches = {
  makePatch('PlayerWallet.CanAfford',   0x4C28E0, {0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3}),
  makePatch('PlayerWallet.TrySubtract', 0x4C2D00, {0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3}),
  makePatch('ShopPanel.CalculatePrice', 0x4F0220, {0x0F, 0x57, 0xC0, 0xC3}),
}

if EXPERIMENTAL_ZERO_TICKET_PRICE_MULT then
  patches[#patches + 1] = makePatch('LoanPanel.GetTicketPriceMult', 0x4A7630, {0x0F, 0x57, 0xC0, 0xC3})
end

for _, p in ipairs(patches) do
  p.addr = base + p.rva
end

_G.scritchy_free_tickets_patch = _G.scritchy_free_tickets_patch or {}
local state = _G.scritchy_free_tickets_patch

local function clearStaleState(reason)
  state.enabled = false
  state.patches = nil
  state.pid = nil
  state.base = nil
  return 'stale_state_cleared=' .. tostring(reason)
end

local function stateIsStale()
  if not state.enabled or not state.patches then
    return false, nil
  end
  if state.pid ~= openedPid then
    return true, 'pid'
  end
  if state.base ~= base then
    return true, 'base'
  end
  for _, p in ipairs(state.patches) do
    if not p.addr or not readBytesSafe(p.addr, p.size) then
      return true, 'read_fail_' .. tostring(p.name)
    end
  end
  return false, nil
end

local stale, staleReason = stateIsStale()
local staleSummary = nil
if stale then
  staleSummary = clearStaleState(staleReason)
end

local summary = {}
summary[#summary + 1] = string.format('base=0x%X', base)
summary[#summary + 1] = 'pid=' .. tostring(openedPid)
if staleSummary then summary[#summary + 1] = staleSummary end
summary[#summary + 1] = 'experimental_ticket_mult=' .. tostring(EXPERIMENTAL_ZERO_TICKET_PRICE_MULT)

local mode = tostring(SCRITCHY_FREE_TICKETS_MODE or 'dryrun'):lower()
summary[#summary + 1] = 'mode_request=' .. mode

if mode ~= 'enable' and mode ~= 'disable' then
  for _, p in ipairs(patches) do
    summary[#summary + 1] = string.format('%s_ADDR=0x%X BYTES[%s]', p.name, p.addr, bytesToHex(readBytesSafe(p.addr, p.size)))
  end
  summary[#summary + 1] = 'mode=DRYRUN'
elseif mode == 'disable' then
  if not state.patches then
    summary[#summary + 1] = 'mode=RESTORE_NO_STATE'
    return table.concat(summary, ' | ')
  end
  local restored = 0
  for i, p in ipairs(state.patches) do
    summary[#summary + 1] = restorePatch(p)
    restored = restored + 1
  end
  state.enabled = false
  state.patches = nil
  summary[#summary + 1] = 'mode=RESTORE restored=' .. tostring(restored)
elseif mode == 'enable' then
  if state.enabled and state.patches then
    local already = 0
    for _, p in ipairs(state.patches) do
      local current = readBytesSafe(p.addr, p.size)
      if bytesEqual(current, p.onBytes) then
        already = already + 1
      end
      summary[#summary + 1] = string.format('%s=ALREADY_STATE[%s]', p.name, bytesToHex(current))
    end
    summary[#summary + 1] = 'mode=ENABLE_ALREADY already=' .. tostring(already)
    return table.concat(summary, ' | ')
  end
  local externalPatched = {}
  for _, p in ipairs(patches) do
    local current = readBytesSafe(p.addr, p.size)
    if bytesEqual(current, p.onBytes) then
      externalPatched[#externalPatched + 1] = p.name
    end
  end
  if #externalPatched > 0 then
    summary[#summary + 1] = 'ERR already_patched_without_saved_original=' .. table.concat(externalPatched, ',')
    return table.concat(summary, ' | ')
  end
  state.patches = patches
  local patched = 0
  for i, p in ipairs(state.patches) do
    summary[#summary + 1] = enablePatch(p)
    patched = patched + 1
  end
  state.enabled = true
  state.pid = openedPid
  state.base = base
  summary[#summary + 1] = 'mode=ENABLE patched=' .. tostring(patched)
end

local result = table.concat(summary, ' | ')
print(result)
return result

