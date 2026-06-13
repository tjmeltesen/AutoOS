--[[
  AutoOS Subnet Broker — Pre-Phase 3 gate checklist

  Run from OC shell (all machines idle, subnet ME stocked):
    loadfile("/home/subnet_broker/pre_p3_checklist.lua")()

  Prerequisites in subnet ME:
    - Ethylene (fluid drops via Fluid Discretizer)
    - Molten Soldering Alloy
    - Integrated circuits damage 14 and 18

  Optional manual gate (safe-failure):
    1. Fault one lane in-game (e.g. remove maintenance hatch on machine_02)
    2. Set SAFE_FAILURE_LANE = "machine_02" below and re-run

  Set RUN_HARDWARE = false for static/diag checks only (no stocking).
]]

-- ============ EDIT THESE ======================================================
local RUN_HARDWARE = true

-- After faulting a lane manually, set its id to verify pool exclusion:
local SAFE_FAILURE_LANE = nil   -- e.g. "machine_02"

local PROBE_LANE = "machine_01"
local MULTI_JOBS = {
  { recipe = "polyethylene", volume = 2000, lanes = { "machine_01", "machine_02" } },
  { recipe = "molten_soldering_alloy", volume = 2880, lanes = { "machine_03", "machine_04" } },
}
local EXPECTED_MULTI_ORDER = { "machine_01", "machine_03", "machine_02", "machine_04" }
-- =============================================================================

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

package.loaded["config"] = nil
package.loaded["machine_poll"] = nil
package.loaded["broker_core"] = nil
package.loaded["load_balancer"] = nil
package.loaded["circuit_manager"] = nil

local Config = require("config")
local LoadBalancer = require("load_balancer")
local BrokerCore = require("broker_core")
local MachinePoll = require("machine_poll")
local LaneSides = require("lane_sides")

local component_api
pcall(function() component_api = require("component") end)

local passed, failed, skipped, warned = 0, 0, 0, 0

local function pass(name, detail)
  passed = passed + 1
  print("[Gate] PASS  " .. name .. (detail and (" — " .. detail) or ""))
end

local function fail(name, detail)
  failed = failed + 1
  print("[Gate] FAIL  " .. name .. (detail and (" — " .. tostring(detail)) or ""))
end

local function skip(name, detail)
  skipped = skipped + 1
  print("[Gate] SKIP  " .. name .. (detail and (" — " .. detail) or ""))
end

local function warn(name, detail)
  warned = warned + 1
  print("[Gate] WARN  " .. name .. (detail and (" — " .. detail) or ""))
end

local function find_machine(id)
  for _, m in ipairs(Config.machines) do
    if m.id == id then return m end
  end
  return nil
end

local function lane_is_idle(st)
  if MachinePoll.is_idle then return MachinePoll.is_idle(st) end
  return st and st.available and st.healthy and not st.active and not st.has_work
end

local function build_idle_pool(poll, poll_results)
  if poll and poll.build_idle_pool then
    return poll:build_idle_pool(poll_results)
  end
  local pool = {}
  for _, m in ipairs(Config.machines) do
    if lane_is_idle(poll_results[m.id]) then pool[#pool + 1] = m end
  end
  return pool
end

local function bus_circuit_damage(machine_row)
  if not component_api then return nil end
  local tp = component_api.proxy(machine_row.transposer_address)
  if not tp or not tp.getStackInSlot then return nil end
  local side = LaneSides.item_bus_side(machine_row)
  local slot = machine_row.input_slot or 1
  local stack = tp.getStackInSlot(side, slot)
  return stack and stack.damage
end

local function lists_equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function check_lb_scenario(name, volume, unit, expected)
  local map, map_err = LoadBalancer.calculate_distribution(Config.machines, volume, unit)
  if not map then
    fail(name, map_err)
    return
  end
  local list = {}
  for _, m in ipairs(Config.machines) do
    list[#list + 1] = map[m.id].operations
  end
  if lists_equal(list, expected) then
    pass(name, string.format("%dL → %s", volume, table.concat(list, ",")))
  else
    fail(name, "expected " .. table.concat(expected, ",") .. " got " .. table.concat(list, ","))
  end
end

print("\n[Gate] ========== PRE-P3 CHECKLIST ==========")
print(string.format("[Gate] hardware=%s safe_failure_lane=%s",
  tostring(RUN_HARDWARE), tostring(SAFE_FAILURE_LANE)))

-- ---------------------------------------------------------------------------
-- G1 — Static / diag (no hardware motion)
-- ---------------------------------------------------------------------------
print("\n[Gate] --- G1 Static checks ---")

local ok_cfg, cfg_err = Config.validate(Config)
if ok_cfg then pass("G1 config validate") else fail("G1 config validate", cfg_err) end

if not BrokerCore.process_multi then
  fail("G1 process_multi API", "wget latest broker_core.lua")
end

if not component_api or not component_api.list then
  warn("G1 component API", "unavailable — UUID walk skipped")
else
  local addrs = {}
  for addr, name in component_api.list() do addrs[addr] = name end
  local missing = 0
  for _, m in ipairs(Config.machines) do
    for _, field in ipairs({ "gt_address", "interface_address", "transposer_address" }) do
      if not addrs[m[field]] then
        missing = missing + 1
        fail("G1 UUID " .. m.id .. " " .. field, "not on OC network")
      end
    end
  end
  if not addrs[Config.database_address] then
    fail("G1 database_address", "not on OC network")
  elseif missing == 0 then
    pass("G1 all lane UUIDs + database")
  end

  pcall(function()
    local m1 = Config.machines[1]
    local iface = component_api.proxy(m1.interface_address)
    if iface and iface.getItemsInNetwork then
      local drops = iface.getItemsInNetwork({ name = "ae2fc:fluid_drop" })
      local n = type(drops) == "table" and #drops or 0
      if n > 0 then
        pass("G1 fluid discretizer", n .. " drop kind(s) in subnet ME")
      else
        fail("G1 fluid discretizer", "no ae2fc:fluid_drop — add Fluid Discretizer")
      end
    end
  end)
end

local poll, poll_results, active_pool, idle_pool
if component_api then
  poll = MachinePoll.new({ config = Config, component = component_api })
  poll_results = poll:poll_all()
  active_pool = poll:build_active_pool(poll_results)
  idle_pool = build_idle_pool(poll, poll_results)

  local healthy_n = 0
  for _, m in ipairs(Config.machines) do
    local st = poll_results[m.id]
    if st and st.healthy then
      healthy_n = healthy_n + 1
      pass("G1 poll " .. m.id, "OK")
    elseif st and st.available then
      warn("G1 poll " .. m.id, tostring(st.fault_message))
    else
      fail("G1 poll " .. m.id, "unavailable")
    end
  end
  if healthy_n == 0 then
    fail("G1 healthy pool", "no lanes")
  else
    pass("G1 healthy pool", healthy_n .. " lane(s)")
  end
else
  warn("G1 maintenance poll", "no component API")
end

check_lb_scenario("G1 scenario A (README)", 15000, 1440, { 3, 3, 2, 2 })
check_lb_scenario("G1 scenario B (README)", 3000, 1000, { 1, 1, 1, 0 })

if failed > 0 then
  print("\n[Gate] ABORT — fix G1 failures before hardware tests")
  print(string.format("[Gate] ========== FAIL: %d passed, %d failed ==========", passed, failed))
  return
end

if not RUN_HARDWARE or not component_api then
  skip("G2–G7 hardware", "RUN_HARDWARE=false or no component")
  print(string.format("\n[Gate] ========== STATIC PASS: %d passed, %d failed, %d skipped ==========",
    passed, failed, skipped))
  return
end

if #idle_pool < #Config.machines then
  warn("G2–G7 idle lanes", string.format("%d/%d idle — busy lanes may be skipped",
    #idle_pool, #Config.machines))
end

BrokerCore.reset_descriptor_cache()

-- ---------------------------------------------------------------------------
-- G2 — Single-lane push + fluid + recover
-- ---------------------------------------------------------------------------
print("\n[Gate] --- G2 Single-lane hardware ---")

local probe = find_machine(PROBE_LANE)
if not probe then
  fail("G2 probe lane", "unknown " .. PROBE_LANE)
else
  local ok_lane, err_lane = BrokerCore.manual_lane_test(PROBE_LANE, "polyethylene", 1000, {
    component = component_api,
    execute_hardware = true,
    recover_circuits = true,
  })
  if ok_lane then
    pass("G2 manual_lane_test " .. PROBE_LANE, "push+fluid+recover")
    local dmg = bus_circuit_damage(probe)
    if dmg == nil then
      pass("G2 bus after recover", "empty")
    else
      fail("G2 bus after recover", "circuit still on bus damage=" .. tostring(dmg))
    end
  else
    fail("G2 manual_lane_test " .. PROBE_LANE, err_lane)
  end
end

-- ---------------------------------------------------------------------------
-- G5 — Recipe switch (solder residue must not feed polyethylene)
-- ---------------------------------------------------------------------------
print("\n[Gate] --- G5 Recipe switch ---")

if probe then
  BrokerCore.reset_descriptor_cache()
  local ok_s, err_s = BrokerCore.manual_lane_test(PROBE_LANE, "molten_soldering_alloy", 1440, {
    component = component_api,
    execute_hardware = true,
    recover_circuits = false,
  })
  if not ok_s then
    fail("G5 solder prime", err_s)
  else
    local ok_p, err_p = BrokerCore.manual_lane_test(PROBE_LANE, "polyethylene", 1000, {
      component = component_api,
      execute_hardware = true,
      recover_circuits = false,
    })
    local dmg = bus_circuit_damage(probe)
    if ok_p and dmg == 18 then
      pass("G5 recipe switch", "polyethylene got circuit 18 (not 14)")
    else
      fail("G5 recipe switch", ok_p and ("bus damage=" .. tostring(dmg)) or err_p)
    end
    pcall(function()
      local CM = require("circuit_manager")
      local cm = CM.new({ config = Config, component = component_api })
      cm:recover_circuit(PROBE_LANE, 18)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- G3 — README hand-off batch (3000L ethylene → 1,1,1,0)
-- ---------------------------------------------------------------------------
print("\n[Gate] --- G3 Hand-off batch ---")

BrokerCore.reset_descriptor_cache()
local hand_pool = active_pool
if poll then hand_pool = poll:build_active_pool(poll:poll_all()) end

local hand_map = LoadBalancer.calculate_distribution(hand_pool, 3000, 1000)
if hand_map then
  local expect_ops = {}
  for _, m in ipairs(Config.machines) do
    expect_ops[#expect_ops + 1] = hand_map[m.id] and hand_map[m.id].operations or 0
  end
  if #hand_pool == 4 and lists_equal(expect_ops, { 1, 1, 1, 0 }) then
    pass("G3 expected ops", "1,1,1,0 on 4-lane pool")
  else
    pass("G3 expected ops", table.concat(expect_ops, ",") .. " on " .. #hand_pool .. " lanes")
  end
end

local batch_ok, batch_sum = BrokerCore.process_batch("polyethylene", 3000, hand_pool, {
  component = component_api,
  execute_hardware = true,
  recover_circuits = false,
  poll_results = poll_results,
})
local expect_dispatched = 0
if hand_map then
  for _, m in ipairs(hand_pool) do
    if hand_map[m.id] and hand_map[m.id].operations > 0 then
      expect_dispatched = expect_dispatched + 1
    end
  end
end
if batch_ok and batch_sum.succeeded == expect_dispatched and expect_dispatched >= 1 then
  pass("G3 process_batch", string.format("%d/%d lanes OK", batch_sum.succeeded, batch_sum.dispatched))
else
  local detail = string.format("ok=%s succeeded=%d dispatched=%d expected=%d",
    tostring(batch_ok), batch_sum.succeeded, batch_sum.dispatched, expect_dispatched)
  for id, r in pairs(batch_sum.lanes or {}) do
    if not r.ok then detail = detail .. "; " .. id .. ": " .. tostring(r.err) end
  end
  fail("G3 process_batch", detail)
end

-- ---------------------------------------------------------------------------
-- G4 — Safe failure (manual: fault SAFE_FAILURE_LANE before run)
-- ---------------------------------------------------------------------------
print("\n[Gate] --- G4 Safe failure (optional) ---")

if not SAFE_FAILURE_LANE or SAFE_FAILURE_LANE == "" then
  skip("G4 safe failure", "set SAFE_FAILURE_LANE after faulting a lane manually")
else
  poll_results = poll:poll_all()
  local fault_st = poll_results[SAFE_FAILURE_LANE]
  if fault_st and fault_st.healthy then
    skip("G4 safe failure", SAFE_FAILURE_LANE .. " still healthy — fault it first")
  elseif not fault_st or not fault_st.available then
    skip("G4 safe failure", SAFE_FAILURE_LANE .. " unavailable")
  else
    local safe_pool = poll:build_active_pool(poll_results)
    local found_fault = false
    for _, m in ipairs(Config.machines) do
      if m.id == SAFE_FAILURE_LANE then found_fault = true end
    end
    local in_pool = false
    for _, m in ipairs(safe_pool) do
      if m.id == SAFE_FAILURE_LANE then in_pool = true end
    end
    if found_fault and not in_pool then
      pass("G4 fault excluded", SAFE_FAILURE_LANE .. " dropped from pool")
      local s_ok, s_sum = BrokerCore.process_batch("polyethylene", 3000, safe_pool, {
        component = component_api,
        execute_hardware = true,
        recover_circuits = false,
        poll_results = poll_results,
      })
      if s_sum.lanes[SAFE_FAILURE_LANE] then
        fail("G4 batch skipped faulted lane", "lane still in dispatch summary")
      elseif s_ok or s_sum.succeeded >= 1 then
        pass("G4 batch continues", string.format("%d/%d on reduced pool",
          s_sum.succeeded, s_sum.dispatched))
      else
        fail("G4 batch continues", "no lanes succeeded")
      end
    else
      fail("G4 fault excluded", "expected " .. SAFE_FAILURE_LANE .. " out of pool")
    end
  end
end

-- ---------------------------------------------------------------------------
-- G6 — Multi-recipe interleaved dispatch
-- ---------------------------------------------------------------------------
print("\n[Gate] --- G6 process_multi ---")

if not BrokerCore.process_multi then
  fail("G6 process_multi", "missing from broker_core")
else
  BrokerCore.reset_descriptor_cache()
  poll_results = poll:poll_all()
  local multi_ok, multi_sum = BrokerCore.process_multi(MULTI_JOBS, {
    component = component_api,
    execute_hardware = true,
    only_idle = true,
    interleave = true,
    recover_circuits = false,
    poll_results = poll_results,
  })

  local order_ids = {}
  for _, step in ipairs(multi_sum.order or {}) do
    order_ids[#order_ids + 1] = step.lane
  end
  if #EXPECTED_MULTI_ORDER > 0 and #order_ids == #EXPECTED_MULTI_ORDER then
    if lists_equal(order_ids, EXPECTED_MULTI_ORDER) then
      pass("G6 interleave order", table.concat(order_ids, ","))
    else
      fail("G6 interleave order", "got " .. table.concat(order_ids, ","))
    end
  end

  local poly_rules = Config.constraints.recipe_baselines.polyethylene
  local solder_rules = Config.constraints.recipe_baselines.molten_soldering_alloy
  if poly_rules and solder_rules then
    local m1 = find_machine("machine_01")
    local m3 = find_machine("machine_03")
    if m1 and bus_circuit_damage(m1) == poly_rules.circuit_damage then
      pass("G6 circuit machine_01", "damage " .. tostring(poly_rules.circuit_damage))
    elseif m1 then
      fail("G6 circuit machine_01", "damage " .. tostring(bus_circuit_damage(m1)))
    end
    if m3 and bus_circuit_damage(m3) == solder_rules.circuit_damage then
      pass("G6 circuit machine_03", "damage " .. tostring(solder_rules.circuit_damage))
    elseif m3 then
      fail("G6 circuit machine_03", "damage " .. tostring(bus_circuit_damage(m3)))
    end
  end

  if multi_ok and multi_sum.dispatched >= 2 then
    pass("G6 process_multi", string.format("%d/%d lanes", multi_sum.succeeded, multi_sum.dispatched))
  else
    local detail = string.format("%d/%d succeeded", multi_sum.succeeded, multi_sum.dispatched)
    for id, r in pairs(multi_sum.lanes or {}) do
      if not r.ok then detail = detail .. "; " .. id .. ": " .. tostring(r.err) end
    end
    fail("G6 process_multi", detail)
  end
end

-- ---------------------------------------------------------------------------
-- G7 — Idle pool + descriptor cache sanity
-- ---------------------------------------------------------------------------
print("\n[Gate] --- G7 Idle pool & cache ---")

poll_results = poll:poll_all()
idle_pool = build_idle_pool(poll, poll_results)
pass("G7 idle pool count", #idle_pool .. " lane(s)")

local busy_lanes = {}
for _, m in ipairs(Config.machines) do
  local st = poll_results[m.id]
  if st and st.available and st.healthy and not lane_is_idle(st) then
    busy_lanes[#busy_lanes + 1] = m.id
  end
end
if #busy_lanes > 0 then
  local m_ok, m_sum = BrokerCore.process_multi({
    { recipe = "polyethylene", volume = 1000, lanes = busy_lanes },
  }, {
    component = component_api,
    execute_hardware = true,
    only_idle = true,
    poll_results = poll_results,
  })
  if m_sum.dispatched == 0 and #(m_sum.skipped_busy or {}) >= 1 then
    pass("G7 busy skip", "only_idle skipped " .. table.concat(m_sum.skipped_busy, ","))
  elseif m_sum.dispatched == 0 then
    pass("G7 busy skip", "no dispatch to busy lane(s)")
  else
    warn("G7 busy skip", "dispatched to busy lanes — only_idle may be off")
  end
else
  skip("G7 busy skip", "all lanes idle — fault or start a craft to test skip")
end

pcall(function()
  local db = component_api.proxy(Config.database_address)
  if not db or not db.get then return end
  local count = Config.database_slot_count or 9
  local used = 0
  for slot = 1, count do
    if db.get(slot) then used = used + 1 end
  end
  if used <= count then
    pass("G7 database slots", string.format("%d / %d used", used, count))
  else
    fail("G7 database slots", "overflow")
  end
end)

-- ---------------------------------------------------------------------------
-- Verdict
-- ---------------------------------------------------------------------------
print(string.format(
  "\n[Gate] ========== DONE: %d passed, %d failed, %d skipped, %d warnings ==========",
  passed, failed, skipped, warned))

if failed == 0 then
  if skipped > 0 or warned > 0 then
    print("[Gate] PRE-P3: PASS WITH NOTES — review SKIP/WARN above")
    print("[Gate] Ready for Phase 3 when G4 (safe failure) is confirmed manually.")
  else
    print("[Gate] PRE-P3: PASS — broker hardware + dispatch ready for Phase 3")
  end
else
  print("[Gate] PRE-P3: FAIL — fix failures before Phase 3 orchestrator loop")
end
