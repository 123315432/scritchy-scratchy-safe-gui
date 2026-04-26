-- scritchy_safe_suite.lua - explicit safe dispatcher
-- GUI should call only these whitelisted actions, never arbitrary Lua.
openProcess('ScritchyScratchy.exe')
local function scriptRoot()
  local source = debug.getinfo(1, 'S').source or ''
  local path = source:gsub('^@', '')
  return path:match('^(.*[\\/])') or ''
end
local ROOT = scriptRoot()
local action = tostring(SCRITCHY_SAFE_ACTION or 'dump')
SCRITCHY_SAFE_ACTION = nil
local function clearProcessCaches()
  rawset(_G, 'SCRITCHY_CACHED_SAVEDATA', nil)
  rawset(_G, 'SCRITCHY_SAVEDATA_STATIC_ADDR', nil)
  rawset(_G, 'SCRITCHY_SAVEDATA_CURRENT_OFFSET', nil)
  for _, className in ipairs({'SubscriptionBot','EggTimer','Fan','Mundo','ScratchBot','SpellBook','PlayerScratching','SuperJackpotManager','TicketShop','PrestigeManager','PlayerWallet','TicketProgressionManager'}) do
    rawset(_G, 'SCRITCHY_CACHED_' .. className, nil)
  end
end
local pidNow = getOpenedProcessID and getOpenedProcessID() or nil
local pidCached = rawget(_G, 'SCRITCHY_CACHE_PID')
if pidNow and pidNow ~= pidCached then
  clearProcessCaches()
  rawset(_G, 'SCRITCHY_CACHE_PID', pidNow)
end
local function clearGlobals(names)
  for _, name in ipairs(names) do _G[name] = nil end
end
local SYMBOL_GLOBALS = {'SCRITCHY_SYMBOL_TICKET','SCRITCHY_SYMBOL_ID','SCRITCHY_SYMBOL_TYPE','SCRITCHY_SYMBOL_VALUE','SCRITCHY_SYMBOL_LUCK_INDEX','SCRITCHY_SYMBOL_DRYRUN'}
local SUB_RUNTIME_GLOBALS = {'SCRITCHY_SUB_PROCESSING_DURATION','SCRITCHY_SUB_MAX_TICKET_COUNT','SCRITCHY_SUB_PAUSED','SCRITCHY_SUB_PROCESSING_SPEED_MULT'}
local GADGET_RUNTIME_GLOBALS = {'SCRITCHY_GADGET_MODE','SCRITCHY_EGGTIMER_BATTERY_CAPACITY_MULT','SCRITCHY_EGGTIMER_BATTERY_CHARGE_MULT','SCRITCHY_EGGTIMER_MULT_MULTIPLIER','SCRITCHY_FAN_BATTERY_CAPACITY_MULT','SCRITCHY_FAN_BATTERY_CHARGE_MULT','SCRITCHY_FAN_SPEED_MULT','SCRITCHY_MUNDO_CLAIM_SPEED_MULT','SCRITCHY_SCRATCHBOT_CAPACITY','SCRITCHY_SCRATCHBOT_STRENGTH','SCRITCHY_SCRATCHBOT_SPEED_MULT','SCRITCHY_SCRATCHBOT_EXTRA_SPEED','SCRITCHY_SCRATCHBOT_EXTRA_CAPACITY','SCRITCHY_SCRATCHBOT_EXTRA_STRENGTH','SCRITCHY_SPELLBOOK_RECHARGE_SPEED_MULT'}
local EXPERIMENTAL_RUNTIME_GLOBALS = {'SCRITCHY_EXPERIMENTAL_MODE','SCRITCHY_SCRATCHBOT_PROCESSING_DURATION','SCRITCHY_MUNDO_PAUSED'}
local HELPER_UPGRADE_GLOBALS = {'SCRITCHY_HELPER_UPGRADE_MODE','SCRITCHY_UPGRADE_FAN','SCRITCHY_UPGRADE_FAN_SPEED','SCRITCHY_UPGRADE_FAN_BATTERY','SCRITCHY_UPGRADE_MUNDO','SCRITCHY_UPGRADE_MUNDO_SPEED','SCRITCHY_UPGRADE_SPELL_BOOK','SCRITCHY_UPGRADE_SPELL_CHARGE_SPEED','SCRITCHY_UPGRADE_EGG_TIMER','SCRITCHY_UPGRADE_TIMER_CAPACITY','SCRITCHY_UPGRADE_TIMER_CHARGE','SCRITCHY_UPGRADE_WARP_SPEED'}
local HELPER_STATE_GLOBALS = {'SCRITCHY_HELPER_STATE_MODE','SCRITCHY_ELECTRIC_FAN_CHARGE_LEFT','SCRITCHY_FAN_PAUSED','SCRITCHY_EGG_TIMER_CHARGE_LEFT','SCRITCHY_MUNDO_DEAD','SCRITCHY_TRASH_CAN_DEAD'}
local TICKET_PROGRESS_GLOBALS = {'SCRITCHY_TICKET_PROGRESS_MODE','SCRITCHY_TICKET_ID','SCRITCHY_TICKET_LEVEL','SCRITCHY_TICKET_XP'}
local LOAN_GLOBALS = {'SCRITCHY_LOAN_MODE','SCRITCHY_LOAN_COUNT','SCRITCHY_LOAN_LIST_SIZE','SCRITCHY_LOAN_INDEX','SCRITCHY_LOAN_NUM','SCRITCHY_LOAN_SEVERITY','SCRITCHY_LOAN_AMOUNT'}
local SINGLE_PERK_GLOBALS = {'SCRITCHY_SINGLE_PERK_MODE','SCRITCHY_SINGLE_PERK_TARGET','SCRITCHY_SINGLE_PERK_COUNT','SCRITCHY_SINGLE_PERK_TUPLE_COUNT','SCRITCHY_SINGLE_PERK_PERKDATA_COUNT','SCRITCHY_SINGLE_PERK_SAVE_COUNT'}
local AUTOMATION_PERK_GLOBALS = {'SCRITCHY_AUTOMATION_PERK_COUNT'}
local ONLINE_UNLOCK_GLOBALS = {'SCRITCHY_UNLOCK_LEVEL','SCRITCHY_UNLOCK_XP','SCRITCHY_MIRROR_SUPER_JACKPOTS'}
local SJP_GLOBALS = {'SJP_CHANCE_VALUE'}
local function run(path)
  local ok, res = pcall(dofile, ROOT .. path)
  return tostring(ok) .. ' :: ' .. tostring(res)
end
if action == 'dump' then
  return run('dump_pointer_chains.lua')
elseif action == 'runtime_status' then
  return run('runtime_status.lua')
elseif action == 'online_unlock' then
  local r = run('online_persist_unlock.lua')
  clearGlobals(ONLINE_UNLOCK_GLOBALS)
  return r
elseif action == 'free_dryrun' then
  SCRITCHY_FREE_TICKETS_MODE = nil
  return run('free_tickets.lua')
elseif action == 'free_enable' then
  SCRITCHY_FREE_TICKETS_MODE = 'enable'
  local r = run('free_tickets.lua')
  SCRITCHY_FREE_TICKETS_MODE = nil
  return r
elseif action == 'free_disable' then
  SCRITCHY_FREE_TICKETS_MODE = 'disable'
  local r = run('free_tickets.lua')
  SCRITCHY_FREE_TICKETS_MODE = nil
  return r
elseif action == 'sjp_v3' then
  local r = run('patch_sjp_v3.lua')
  clearGlobals(SJP_GLOBALS)
  return r
elseif action == 'sjp_max' then
  local r = run('sjp_max_chance.lua')
  clearGlobals(SJP_GLOBALS)
  return r
elseif action == 'scratch_status' then
  clearGlobals({'SCRITCHY_SCRATCH_PARTICLE_SPEED','SCRITCHY_MOUSE_VELOCITY_MAX','SCRITCHY_SCRATCH_CHECKS_PER_SECOND','SCRITCHY_SCRATCH_LUCK','SCRITCHY_LUCK_REDUCTION','SCRITCHY_TOOL_STRENGTH','SCRITCHY_TOOL_SIZE','SCRITCHY_TOOL_SIZE_REDUCTION'})
  SCRITCHY_SCRATCH_MODE = 'status'
  return run('scratch_runtime_fields.lua')
elseif action == 'scratch_apply' then
  SCRITCHY_SCRATCH_MODE = 'apply'
  local r = run('scratch_runtime_fields.lua')
  SCRITCHY_SCRATCH_MODE = 'status'
  clearGlobals({'SCRITCHY_SCRATCH_PARTICLE_SPEED','SCRITCHY_MOUSE_VELOCITY_MAX','SCRITCHY_SCRATCH_CHECKS_PER_SECOND','SCRITCHY_SCRATCH_LUCK','SCRITCHY_LUCK_REDUCTION','SCRITCHY_TOOL_STRENGTH','SCRITCHY_TOOL_SIZE','SCRITCHY_TOOL_SIZE_REDUCTION'})
  return r
elseif action == 'bot_upgrade_status' then
  clearGlobals({'SCRITCHY_BOT_UNLOCK','SCRITCHY_BOT_SPEED','SCRITCHY_BOT_CAPACITY','SCRITCHY_BOT_STRENGTH'})
  SCRITCHY_BOT_MODE = 'status'
  return run('bot_upgrade_fields.lua')
elseif action == 'bot_upgrade_apply' then
  SCRITCHY_BOT_MODE = 'apply'
  local r = run('bot_upgrade_fields.lua')
  SCRITCHY_BOT_MODE = 'status'
  clearGlobals({'SCRITCHY_BOT_UNLOCK','SCRITCHY_BOT_SPEED','SCRITCHY_BOT_CAPACITY','SCRITCHY_BOT_STRENGTH'})
  return r
elseif action == 'subscription_bot_status' then
  clearGlobals({'SCRITCHY_SUB_BOT_UNLOCK','SCRITCHY_BUYING_SPEED'})
  SCRITCHY_SUB_BOT_MODE = 'status'
  return run('subscription_bot_fields.lua')
elseif action == 'subscription_bot_apply' then
  SCRITCHY_SUB_BOT_MODE = 'apply'
  local r = run('subscription_bot_fields.lua')
  SCRITCHY_SUB_BOT_MODE = 'status'
  clearGlobals({'SCRITCHY_SUB_BOT_UNLOCK','SCRITCHY_BUYING_SPEED'})
  return r
elseif action == 'subscription_runtime_status' then
  clearGlobals(SUB_RUNTIME_GLOBALS)
  SCRITCHY_SUB_RUNTIME_MODE = 'status'
  return run('subscription_bot_runtime.lua')
elseif action == 'subscription_runtime_apply' then
  SCRITCHY_SUB_RUNTIME_MODE = 'apply'
  local r = run('subscription_bot_runtime.lua')
  SCRITCHY_SUB_RUNTIME_MODE = 'status'
  clearGlobals(SUB_RUNTIME_GLOBALS)
  return r
elseif action == 'helper_upgrade_status' then
  clearGlobals(HELPER_UPGRADE_GLOBALS)
  SCRITCHY_HELPER_UPGRADE_MODE = 'status'
  local r = run('helper_upgrade_fields.lua')
  clearGlobals(HELPER_UPGRADE_GLOBALS)
  return r
elseif action == 'helper_upgrade_apply' then
  SCRITCHY_HELPER_UPGRADE_MODE = 'apply'
  local r = run('helper_upgrade_fields.lua')
  clearGlobals(HELPER_UPGRADE_GLOBALS)
  return r
elseif action == 'helper_state_status' then
  clearGlobals(HELPER_STATE_GLOBALS)
  SCRITCHY_HELPER_STATE_MODE = 'status'
  local r = run('helper_state_fields.lua')
  clearGlobals(HELPER_STATE_GLOBALS)
  return r
elseif action == 'helper_state_apply' then
  SCRITCHY_HELPER_STATE_MODE = 'apply'
  local r = run('helper_state_fields.lua')
  clearGlobals(HELPER_STATE_GLOBALS)
  return r
elseif action == 'ticket_progress_status' then
  SCRITCHY_TICKET_PROGRESS_MODE = 'status'
  local r = run('ticket_progression_fields.lua')
  clearGlobals(TICKET_PROGRESS_GLOBALS)
  return r
elseif action == 'ticket_progress_apply' then
  SCRITCHY_TICKET_PROGRESS_MODE = 'apply'
  local r = run('ticket_progression_fields.lua')
  clearGlobals(TICKET_PROGRESS_GLOBALS)
  return r
elseif action == 'loan_status' then
  clearGlobals(LOAN_GLOBALS)
  SCRITCHY_LOAN_MODE = 'status'
  local r = run('loan_state_fields.lua')
  clearGlobals(LOAN_GLOBALS)
  return r
elseif action == 'loan_apply' then
  SCRITCHY_LOAN_MODE = 'apply'
  local r = run('loan_state_fields.lua')
  clearGlobals(LOAN_GLOBALS)
  return r
elseif action == 'loan_clear' then
  SCRITCHY_LOAN_MODE = 'clear'
  local r = run('loan_state_fields.lua')
  clearGlobals(LOAN_GLOBALS)
  return r
elseif action == 'gadget_runtime_status' then
  clearGlobals(GADGET_RUNTIME_GLOBALS)
  SCRITCHY_GADGET_MODE = 'status'
  local r = run('gadget_runtime_fields.lua')
  clearGlobals(GADGET_RUNTIME_GLOBALS)
  return r
elseif action == 'gadget_runtime_apply' then
  SCRITCHY_GADGET_MODE = 'apply'
  local r = run('gadget_runtime_fields.lua')
  SCRITCHY_GADGET_MODE = 'status'
  clearGlobals(GADGET_RUNTIME_GLOBALS)
  return r
elseif action == 'experimental_runtime_status' then
  clearGlobals(EXPERIMENTAL_RUNTIME_GLOBALS)
  SCRITCHY_EXPERIMENTAL_MODE = 'status'
  local r = run('experimental_runtime_fields.lua')
  clearGlobals(EXPERIMENTAL_RUNTIME_GLOBALS)
  return r
elseif action == 'experimental_runtime_apply' then
  SCRITCHY_EXPERIMENTAL_MODE = 'apply'
  local r = run('experimental_runtime_fields.lua')
  clearGlobals(EXPERIMENTAL_RUNTIME_GLOBALS)
  return r
elseif action == 'rng_enable' then
  SCRITCHY_RNG_V2_UNINSTALL = false
  return run('rng_control_v2.lua')
elseif action == 'rng_disable' then
  SCRITCHY_RNG_V2_UNINSTALL = true
  local r = run('rng_control_v2.lua')
  SCRITCHY_RNG_V2_UNINSTALL = false
  return r
elseif action == 'symbol_dump' then
  SCRITCHY_SYMBOL_MODE = 'dump'
  local r = run('ticket_symbol_chances.lua')
  clearGlobals(SYMBOL_GLOBALS)
  return r
elseif action == 'symbol_apply' then
  SCRITCHY_SYMBOL_MODE = 'apply'
  local r = run('ticket_symbol_chances.lua')
  SCRITCHY_SYMBOL_MODE = 'dump'
  clearGlobals(SYMBOL_GLOBALS)
  return r
elseif action == 'dump_perks' then
  return run('dump_active_perks.lua')
elseif action == 'single_perk_status' then
  SCRITCHY_SINGLE_PERK_MODE = 'status'
  local r = run('single_perk_fields.lua')
  clearGlobals(SINGLE_PERK_GLOBALS)
  return r
elseif action == 'single_perk_apply' then
  SCRITCHY_SINGLE_PERK_MODE = 'apply'
  local r = run('single_perk_fields.lua')
  clearGlobals(SINGLE_PERK_GLOBALS)
  return r
elseif action == 'perk_boost_dryrun' then
  SCRITCHY_PERK_BOOST_DRYRUN = true
  return run('boost_existing_perks.lua')
elseif action == 'perk_boost_apply' then
  SCRITCHY_PERK_BOOST_DRYRUN = false
  local r = run('boost_existing_perks.lua')
  SCRITCHY_PERK_BOOST_DRYRUN = true
  return r
elseif action == 'automation_perks_status' then
  clearGlobals(AUTOMATION_PERK_GLOBALS)
  SCRITCHY_AUTOMATION_PERK_MODE = 'status'
  return run('automation_perks_existing.lua')
elseif action == 'automation_perks_apply' then
  SCRITCHY_AUTOMATION_PERK_MODE = 'apply'
  local r = run('automation_perks_existing.lua')
  SCRITCHY_AUTOMATION_PERK_MODE = 'status'
  clearGlobals(AUTOMATION_PERK_GLOBALS)
  return r
elseif action == 'prestige_safe' then
  SCRITCHY_ALLOW_UNSAFE_ACTIVATEPERK = false
  local r = run('prestige_unlock_v2.lua')
  SCRITCHY_ALLOW_UNSAFE_ACTIVATEPERK = nil
  return r
elseif action == 'tokens_safe' then
  SCRITCHY_ALLOW_SETTOKENS_CALL = false
  local r = run('tokens_set_v2.lua')
  SCRITCHY_ALLOW_SETTOKENS_CALL = nil
  return r
elseif action == 'custom_save_fields' then
  local r = run('custom_save_fields.lua')
  clearGlobals({'SCRITCHY_CUSTOM_MONEY','SCRITCHY_CUSTOM_TOKENS','SCRITCHY_CUSTOM_SOULS','SCRITCHY_CUSTOM_PRESTIGE_CURRENCY','SCRITCHY_CUSTOM_PRESTIGE_COUNT','SCRITCHY_CUSTOM_ACT'})
  return r
elseif action == 'unlock_tickets_safe' then
  SCRITCHY_ALLOW_DEBUGTOOLS_CALLS = false
  local r = run('unlock_all_tickets_v2.lua')
  SCRITCHY_ALLOW_DEBUGTOOLS_CALLS = nil
  return r
else
  return 'ERR unknown SCRITCHY_SAFE_ACTION=' .. action
end
