#!/usr/bin/env lua
--[[
  AutoOS — Phase 2 broker desktop tests (lane hardware against realistic mocks)

  Run: C:\Lua\lua55.exe tests\phase2_broker_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/phase2_broker_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local Mock = require("mock_broker_hardware")
local MaintenanceParse = require("maintenance_parse")
local MachinePoll = require("machine_poll")
local LoadBalancer = require("load_balancer")
local CircuitManager = require("circuit_manager")
local DescriptorCache = require("descriptor_cache")
local FluidLane = require("fluid_lane")
local BrokerCore = require("broker_core")
local Config = require("config")

local ESC = string.char(27)
local function color(code, t) return ESC .. "[" .. code .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function dim(t) return color("2", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write(dim("  -  " .. tostring(detail))) end
  io.write("\n")
end

local function lists_equal(a, b)
  if #a ~= #b then return false end
  for i in ipairs(a) do if a[i] ~= b[i] then return false end end
  return true
end

local CIRCUIT = "gregtech:gt.integrated_circuit"

local function fresh_mock(overrides)
  overrides = overrides or {}
  FluidLane.reset_cache()
  BrokerCore.set_deps({})
  BrokerCore.reset_descriptor_cache()
  return Mock.new({
    machines = Mock.machines_from_config(Config),
    database_address = Config.database_address,
    network_items = overrides.network_items or {
      { name = CIRCUIT, damage = 14, label = "Programmed Circuit", size = 64 },
      { name = CIRCUIT, damage = 18, label = "Programmed Circuit", size = 64 },
    },
    network_fluids = overrides.network_fluids or {
      ["Molten Soldering Alloy"] = 50000,
      ["Ethylene"] = 50000,
    },
    discretizer = overrides.discretizer,
    fluid_buffer = overrides.fluid_buffer,
  })
end

io.write("\n" .. bold("AutoOS Phase 2 — Lane Hardware Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- Maintenance parse -----------------------------------------------------------
check("Problems: 0 healthy", not MaintenanceParse.has_fault({ "Problems: 0 Efficiency: 100.0 %" }))
check("Problems: 1 fault", MaintenanceParse.has_fault({ "Problems: 1" }))

-- Pool building ----------------------------------------------------------------
local mock = fresh_mock()
local poll = MachinePoll.new({ config = Config, component = mock.component })
check("4 healthy → pool of 4", #poll:build_active_pool(poll:poll_all()) == 4)

mock.set_machine_fault("machine_02", true)
local pool3 = poll:build_active_pool(poll:poll_all())
check("fault machine_02 → pool of 3", #pool3 == 3)

local list_safe = {}
local map_safe = LoadBalancer.calculate_distribution(pool3, 14400, 1440)
for _, m in ipairs(pool3) do list_safe[#list_safe + 1] = map_safe[m.id].operations end
check("safe failure 4,3,3", lists_equal(list_safe, { 4, 3, 3 }), table.concat(list_safe, ","))

-- Circuit push / recover --------------------------------------------------------
mock = fresh_mock()
local cm = CircuitManager.new({ config = Config, component = mock.component })

local ok_push, push_err = cm:push_circuit("machine_01", 14)
check("push_circuit ok", ok_push == true, push_err)
local bus = mock.bus_stack("machine_01", 1)
check("circuit really on bus", bus ~= nil and bus.damage == 14)

check("push idempotent (already on bus)", cm:push_circuit("machine_01", 14) == true)

local ok_wrong, wrong_err = cm:push_circuit("machine_01", 18)
check("wrong circuit on bus rejected", ok_wrong == false and tostring(wrong_err):find("recover or clear") ~= nil, wrong_err)

local ok_rec, rec_err = cm:recover_circuit("machine_01", 14)
check("recover_circuit ok", ok_rec == true, rec_err)
check("bus empty after recover", mock.bus_stack("machine_01", 1) == nil)
check("recover idempotent (empty bus)", cm:recover_circuit("machine_01", 14) == true)

-- Wrong circuit recover: damage filter falls back to any circuit on bus.
mock.put_bus_stack("machine_01", 1, { name = CIRCUIT, damage = 18, size = 1 })
local ok_any, any_err = cm:recover_circuit("machine_01", 14)
check("recover wrong damage still clears bus", ok_any == true, any_err)
check("bus empty after wrong-damage recover", mock.bus_stack("machine_01", 1) == nil)

local ok_missing, missing_err = cm:push_circuit("machine_01", 22)
check("push fails when circuit not in ME",
  ok_missing == false and tostring(missing_err):find("empty after stocking") ~= nil, missing_err)

-- Fluid descriptors ---------------------------------------------------------------
mock = fresh_mock()
local dc = DescriptorCache.new({ config = Config, component = mock.component })
local iface1 = mock.component.proxy(Config.machines[1].interface_address)

local function slot_with(db_slots, predicate)
  for slot = 1, (Config.database_slot_count or 25) do
    local e = db_slots[slot]
    if e and predicate(e) then return slot, e end
  end
  return nil
end

local rules = Config.constraints.recipe_baselines["polyethylene"]
local ok_fd, fd_slot = dc:ensure_fluid(iface1, rules)
check("ensure_fluid finds drop item", ok_fd == true, fd_slot)
check("db slot holds fluid drop",
  slot_with(mock.db_slots, function(e) return e.name:find("fluid_drop") ~= nil end) == fd_slot)

local mock_nodisc = fresh_mock({ discretizer = false })
local dc_nd = DescriptorCache.new({ config = Config, component = mock_nodisc.component })
local iface_nd = mock_nodisc.component.proxy(Config.machines[1].interface_address)
local ok_nd, nd_err = dc_nd:ensure_fluid(iface_nd, rules)
check("no discretizer → clear error", ok_nd == false and tostring(nd_err):find("Discretizer") ~= nil, nd_err)

-- Full-volume fluid pump ------------------------------------------------------------
mock = fresh_mock({ fluid_buffer = 1000 })
local row1 = Config.machines[1]
local alloc = { operations = 4, allocated_volume = 5760 }
local ok_lane, lane_err = BrokerCore.execute_lane(row1, alloc, "molten_soldering_alloy", mock.component, {})
check("execute_lane circuit+fluid ok", ok_lane == true, lane_err)
check("full volume delivered (5760 mB, buffer 1000)", mock.hatch_mb("machine_01") == 5760,
  mock.hatch_mb("machine_01") .. " mB")
check("pump looped (multiple transferFluid)", mock.stats.transferFluid >= 6, mock.stats.transferFluid .. " calls")
check("circuit on bus after lane", mock.bus_stack("machine_01", 1) ~= nil)

-- Wrong configured sides → probe recovers ---------------------------------------------
mock = fresh_mock({ fluid_buffer = 1000 })
local wrong_row = {}
for k, v in pairs(Config.machines[1]) do wrong_row[k] = v end
wrong_row.fluid_pull_side = 5      -- physically wrong
wrong_row.interface_fluid_side = 3 -- physically wrong
local ok_probe, probe_err = BrokerCore.execute_lane(wrong_row, { operations = 1, allocated_volume = 1440 },
  "molten_soldering_alloy", mock.component, { push_circuits = false })
check("wrong sides auto-discovered", ok_probe == true, probe_err)
check("probe delivered full volume", mock.hatch_mb("machine_01") == 1440, mock.hatch_mb("machine_01") .. " mB")
local cached = FluidLane.cached_sides("machine_01")
check("working sides cached", cached ~= nil and cached.pull_side == 1 and cached.me_side == 0)

-- Subnet runs dry -----------------------------------------------------------------------
mock = fresh_mock({ network_fluids = { ["Molten Soldering Alloy"] = 1500 }, fluid_buffer = 1000 })
local ok_dry, dry_err = BrokerCore.execute_lane(Config.machines[1], { operations = 2, allocated_volume = 2880 },
  "molten_soldering_alloy", mock.component, { push_circuits = false })
check("dry subnet → partial delivery error",
  ok_dry == false and tostring(dry_err):find("1500") ~= nil, dry_err)

-- Recover after lane ------------------------------------------------------------------------
mock = fresh_mock()
local ok_full, full_err = BrokerCore.execute_lane(Config.machines[1], { operations = 1, allocated_volume = 1440 },
  "molten_soldering_alloy", mock.component, { recover_circuits = true })
check("execute_lane with recover ok", ok_full == true, full_err)
check("bus empty after recover_circuits", mock.bus_stack("machine_01", 1) == nil)

-- Batch continues after a lane failure --------------------------------------------------------
mock = fresh_mock()
mock.break_component(Config.machines[2].transposer_address)
local batch_ok, summary = BrokerCore.process_batch("polyethylene", 3000, Config.machines, {
  component = mock.component,
  execute_hardware = true,
})
check("batch reports failure", batch_ok == false)
check("failed lane counted", summary.failed == 1 and summary.lanes.machine_02 and summary.lanes.machine_02.ok == false)
check("later lanes still ran", summary.succeeded == 2 and mock.hatch_mb("machine_03") == 1000,
  string.format("succeeded=%d m3=%dmB", summary.succeeded, mock.hatch_mb("machine_03")))

-- Healthy batch end-to-end ----------------------------------------------------------------------
mock = fresh_mock()
local all_ok, s2 = BrokerCore.process_batch("polyethylene", 3000, Config.machines, {
  component = mock.component,
  execute_hardware = true,
})
check("healthy batch all lanes ok", all_ok == true and s2.succeeded == 3, string.format("succeeded=%d", s2.succeeded))
check("volumes delivered per lane",
  mock.hatch_mb("machine_01") == 1000 and mock.hatch_mb("machine_02") == 1000 and mock.hatch_mb("machine_03") == 1000)

-- Shared cache: 3-lane batch reuses one circuit slot + one fluid slot (not 6 writes).
mock = fresh_mock()
mock.stats.store = 0
BrokerCore.process_batch("polyethylene", 3000, Config.machines, {
  component = mock.component,
  execute_hardware = true,
})
local circuit_slots, fluid_slots = {}, {}
for slot, entry in pairs(mock.db_slots) do
  if entry.name and entry.name:find("integrated_circuit", 1, true) then
    circuit_slots[slot] = entry.damage
  elseif entry.name and entry.name:find("fluid_drop", 1, true) then
    fluid_slots[slot] = true
  end
end
local n_circuits, n_fluids = 0, 0
local shared_circuit_damage
for _, d in pairs(circuit_slots) do n_circuits = n_circuits + 1; shared_circuit_damage = d end
for _ in pairs(fluid_slots) do n_fluids = n_fluids + 1 end
check("batch shares one circuit descriptor slot", n_circuits == 1 and shared_circuit_damage == 18,
  string.format("%d circuit slots", n_circuits))
check("batch shares one fluid descriptor slot", n_fluids == 1,
  string.format("%d fluid slots", n_fluids))
check("batch cache limits me.store calls", mock.stats.store <= 2,
  string.format("store=%d", mock.stats.store))

-- Database slot cache: hit / miss / LRU / stale / foreign -----------------------------------------
io.write(dim("\n  Database slot cache\n"))

-- Cache hit: two ensure_circuit(18) → same slot, single me.store.
mock = fresh_mock()
local dcc = DescriptorCache.new({ config = Config, component = mock.component })
local ifc = mock.component.proxy(Config.machines[1].interface_address)
local ok1, slot1 = dcc:ensure_circuit(ifc, 18)
local store_after_first = mock.stats.store
local ok2, slot2 = dcc:ensure_circuit(ifc, 18)
check("cache hit reuses slot", ok1 and ok2 and slot1 == slot2, string.format("%s vs %s", tostring(slot1), tostring(slot2)))
check("cache hit skips rewrite (no extra store)", mock.stats.store == store_after_first,
  string.format("store=%d after=%d", mock.stats.store, store_after_first))

-- Cache miss on empty DB → first empty slot (1).
mock = fresh_mock()
dcc = DescriptorCache.new({ config = Config, component = mock.component })
ifc = mock.component.proxy(Config.machines[1].interface_address)
local okm, slotm = dcc:ensure_circuit(ifc, 18)
check("cache miss picks first empty slot", okm and slotm == 1, tostring(slotm))

-- Stale DB hit: cache points at slot but DB content changed → invalidate + reallocate.
mock = fresh_mock()
dcc = DescriptorCache.new({ config = Config, component = mock.component })
ifc = mock.component.proxy(Config.machines[1].interface_address)
local oks, slots = dcc:ensure_circuit(ifc, 18)
mock.db_slots[slots] = { name = "gregtech:gt.integrated_circuit", damage = 14 }  -- external tamper
local oks2, slots2 = dcc:ensure_circuit(ifc, 18)
check("stale slot invalidated + rewritten", oks and oks2
  and mock.db_slots[slots2].damage == 18, string.format("slot=%s dmg=%s", tostring(slots2), tostring(mock.db_slots[slots2] and mock.db_slots[slots2].damage)))

-- DB discovery: pre-seeded slot 7 with circuit 18 → new cache adopts without store.
mock = fresh_mock()
mock.db_slots[7] = { name = CIRCUIT, damage = 18 }
dcc = DescriptorCache.new({ config = Config, component = mock.component })
ifc = mock.component.proxy(Config.machines[1].interface_address)
mock.stats.store = 0
local okd, slotd = dcc:ensure_circuit(ifc, 18)
check("DB discovery adopts existing slot", okd and slotd == 7, tostring(slotd))
check("DB discovery skips me.store", mock.stats.store == 0)

-- Foreign protection: every slot occupied by non-broker entries → fail, nothing cleared.
mock = fresh_mock()
dcc = DescriptorCache.new({ config = Config, component = mock.component })
ifc = mock.component.proxy(Config.machines[1].interface_address)
for s = 1, (Config.database_slot_count or 25) do
  mock.db_slots[s] = { name = "minecraft:stone", damage = 0 }
end
local okf, ferr = dcc:ensure_circuit(ifc, 18)
check("foreign-full DB rejected", okf == false and tostring(ferr):find("database full") ~= nil, ferr)
check("foreign slots untouched", mock.db_slots[1].name == "minecraft:stone")

-- LRU eviction: tiny DB, fill with broker entries, next miss evicts the coldest.
local small_cfg = {}
for k, v in pairs(Config) do small_cfg[k] = v end
small_cfg.database_slot_count = 2
mock = fresh_mock({
  network_items = {
    { name = CIRCUIT, damage = 14, label = "Programmed Circuit", size = 64 },
    { name = CIRCUIT, damage = 18, label = "Programmed Circuit", size = 64 },
    { name = CIRCUIT, damage = 22, label = "Programmed Circuit", size = 64 },
  },
})
dcc = DescriptorCache.new({ config = small_cfg, component = mock.component })
ifc = mock.component.proxy(Config.machines[1].interface_address)
local _, lru_a = dcc:ensure_circuit(ifc, 14)   -- slot for 14
dcc:ensure_circuit(ifc, 18)                     -- slot for 18 (DB now full)
dcc:ensure_circuit(ifc, 14)                     -- touch 14 → 18 becomes coldest
local oke, lru_c = dcc:ensure_circuit(ifc, 22)  -- miss, must evict coldest (18)
check("LRU evict reuses coldest slot", oke == true and mock.db_slots[lru_c].damage == 22, tostring(lru_c))
check("circuit 14 survived (was touched)",
  slot_with(mock.db_slots, function(e) return e.damage == 14 end) ~= nil)
check("circuit 18 evicted (was coldest)",
  slot_with(mock.db_slots, function(e) return e.damage == 18 end) == nil)

-- Recipe switch end to end: stale slot 1 must not feed circuit 14 to a polyethylene lane.
mock = fresh_mock()
mock.db_slots[1] = { name = "gregtech:gt.integrated_circuit", damage = 14 }  -- leftover from a prior recipe
local rok, rsum = BrokerCore.process_batch("polyethylene", 1000, { Config.machines[1] }, {
  component = mock.component,
  execute_hardware = true,
})
local rbus = mock.bus_stack("machine_01", 1)
check("recipe switch pushes correct circuit (18 not 14)",
  rok == true and rbus ~= nil and rbus.damage == 18,
  string.format("ok=%s bus=%s", tostring(rok), tostring(rbus and rbus.damage)))

-- Verify guard: interface stocks wrong circuit → push_circuit fails before transfer.
mock = fresh_mock({
  network_items = { { name = CIRCUIT, damage = 14, label = "Programmed Circuit", size = 64 } },
})
local cmv = CircuitManager.new({
  config = Config,
  component = mock.component,
  descriptor_cache = {
    ensure_circuit = function() return true, 5 end,  -- pretend slot 5 is ready...
  },
})
mock.db_slots[5] = { name = "gregtech:gt.integrated_circuit", damage = 14 }  -- ...but it holds 14
local okv, verr = cmv:push_circuit("machine_01", 18)
check("stocked-wrong-circuit guard trips", okv == false
  and tostring(verr):find("expected 18") ~= nil, verr)
check("wrong circuit not left on bus", mock.bus_stack("machine_01", 1) == nil)

-- process_multi: two recipes interleaved across idle lanes ----------------------
io.write(dim("\n  process_multi\n"))

mock = fresh_mock()
local multi_ok, multi_sum = BrokerCore.process_multi({
  { recipe = "polyethylene", volume = 2000, lanes = { "machine_01", "machine_02" } },
  { recipe = "molten_soldering_alloy", volume = 2880, lanes = { "machine_03", "machine_04" } },
}, {
  component = mock.component,
  execute_hardware = true,
})
check("process_multi all lanes ok", multi_ok == true and multi_sum.succeeded == 4,
  string.format("succeeded=%d", multi_sum.succeeded))
check("polyethylene volumes", mock.hatch_mb("machine_01") == 1000 and mock.hatch_mb("machine_02") == 1000)
check("solder volumes", mock.hatch_mb("machine_03") == 1440 and mock.hatch_mb("machine_04") == 1440)
check("correct circuits per recipe",
  mock.bus_stack("machine_01").damage == 18 and mock.bus_stack("machine_03").damage == 14)

local order_ids = {}
for _, step in ipairs(multi_sum.order or {}) do order_ids[#order_ids + 1] = step.lane end
check("interleaved dispatch order",
  lists_equal(order_ids, { "machine_01", "machine_03", "machine_02", "machine_04" }),
  table.concat(order_ids, ","))

-- Busy lane skipped when only_idle=true -------------------------------------------
mock = fresh_mock()
mock.set_machine_busy("machine_02", true, true)
multi_ok, multi_sum = BrokerCore.process_multi({
  { recipe = "polyethylene", volume = 1000, lanes = { "machine_01", "machine_02" } },
  { recipe = "molten_soldering_alloy", volume = 1440, lanes = { "machine_03" } },
}, {
  component = mock.component,
  execute_hardware = true,
  only_idle = true,
})
check("busy lane skipped", multi_ok == true and multi_sum.succeeded == 2,
  string.format("succeeded=%d skipped=%s", multi_sum.succeeded, table.concat(multi_sum.skipped_busy or {}, ",")))
check("busy lane not stocked", mock.hatch_mb("machine_02") == 0)
check("idle lanes stocked", mock.hatch_mb("machine_01") == 1000 and mock.hatch_mb("machine_03") == 1440)

-- Idle pool helper ----------------------------------------------------------------
mock = fresh_mock()
mock.set_machine_busy("machine_04", true, false)
poll = MachinePoll.new({ config = Config, component = mock.component })
local pr = poll:poll_all()
check("build_idle_pool drops busy", #poll:build_idle_pool(pr) == 3)
check("is_idle false when active", MachinePoll.is_idle(pr.machine_04) == false)

io.write(string.rep("-", 60) .. "\n")
io.write(bold(string.format("Results: %d passed, %d failed\n", passed, failed)))
if failed > 0 then os.exit(1) end
