#!/usr/bin/env lua
--[[
  AutoOS — Phase 2 broker desktop tests

  Run from project root:
    C:\Lua\lua55.exe tests\phase2_broker_test.lua
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
  if ok then
    passed = passed + 1
    io.write(green("  PASS  ") .. name)
  else
    failed = failed + 1
    io.write(red("  FAIL  ") .. name)
  end
  if detail then io.write(dim("  -  " .. tostring(detail))) end
  io.write("\n")
end

local function lists_equal(a, b)
  if #a ~= #b then return false end
  for i, v in ipairs(a) do
    if a[i] ~= b[i] then return false end
  end
  return true
end

io.write("\n" .. bold("AutoOS Phase 2 — Hardware & Control Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

--------------------------------------------------------------------------------
-- maintenance_parse
--------------------------------------------------------------------------------

check("Problems: 0 healthy", not MaintenanceParse.has_fault({ "Problems: 0 Efficiency: 100.0 %" }))
local f1, m1 = MaintenanceParse.has_fault({ "Problems: 1 Efficiency: 0.0 %" })
check("Problems: 1 fault", f1 and m1 ~= nil)
local f2 = MaintenanceParse.has_fault({ "Machine needs a wrench!" })
check("wrench message fault", f2)
check("structure phrase fault",
  MaintenanceParse.has_fault({ "INCOMPLETE STRUCTURE" }))

--------------------------------------------------------------------------------
-- machine_poll
--------------------------------------------------------------------------------

local mock4 = Mock.new({
  machines = Mock.machines_from_config(Config),
  vault_address = Config.circuit_vault.address,
  database_address = Config.database_address,
})
local poll4 = MachinePoll.new({ config = Config, component = mock4.component })
local pool4 = poll4:build_active_pool(poll4:poll_all())
check("4 healthy machines → pool of 4", #pool4 == 4)

mock4.set_machine_fault("reactor_02", true, "Problems: 1")
local pool3 = poll4:build_active_pool(poll4:poll_all())
check("fault on reactor_02 → pool of 3", #pool3 == 3)
check("pool order preserves reactor_01 first", pool3[1].id == "reactor_01")
check("reactor_02 not in pool",
  not poll4:build_active_pool(poll4:poll_all())[2] or pool3[2].id ~= "reactor_02")

--------------------------------------------------------------------------------
-- Safe Failure preview math
--------------------------------------------------------------------------------

local list_safe = {}
local map_safe, _ = LoadBalancer.calculate_distribution(pool3, 14400, 1440)
for _, m in ipairs(pool3) do
  list_safe[#list_safe + 1] = map_safe[m.id].operations
end
check("14400L/1440/3 machines → 4,3,3", lists_equal(list_safe, { 4, 3, 3 }),
  table.concat(list_safe, ","))

--------------------------------------------------------------------------------
-- Config.validate routing
--------------------------------------------------------------------------------

local bad_export = {
  machines = {
    {
      id = "x", gt_address = "a", bus_in = "b", hatch_fluid = "c",
      circuit_route = "export_bus",
    },
  },
  constraints = { recipe_baselines = { t = { fluid_requirement = 100 } } },
}
local bad_ok, bad_err = Config.validate(bad_export)
check("export_bus without bus_export_side rejected",
  bad_ok == nil and bad_err:find("bus_export_side"))

--------------------------------------------------------------------------------
-- circuit_manager export_bus push
--------------------------------------------------------------------------------

local cm_export = CircuitManager.new({
  config = Config,
  component = mock4.component,
  component_types = mock4.component_types,
})
local ok_exp, err_exp = cm_export:push_circuit("reactor_01", 14)
check("export_bus push_circuit ok", ok_exp == true, err_exp)
check("setExportConfiguration called", mock4.stats.setExportConfiguration >= 1)
check("exportIntoSlot called", mock4.stats.exportIntoSlot >= 1)

--------------------------------------------------------------------------------
-- circuit_manager transposer push (bus_in is transposer)
--------------------------------------------------------------------------------

local trans_cfg = {
  subnet_id = "test",
  circuit_vault = { address = "vault-tp" },
  circuit_db_slots = { [14] = 1 },
  database_address = "db-1",
  circuit_item_name = "gregtech:gt.integrated_circuit",
  machines = {
    {
      id = "m1",
      gt_address = "gt-1",
      bus_in = "tp-bus",
      hatch_fluid = "fh-1",
      circuit_route = "transposer",
      transposer_address = "tp-bus",
      transposer_vault_side = 2,
      transposer_to_bus_side = 3,
      gt_bus_slot = 1,
    },
  },
  constraints = { recipe_baselines = { x = { fluid_requirement = 1000 } } },
}

local mock_tp = Mock.new({
  machines = {
    {
      id = "m1", gt_address = "gt-1", bus_in = "tp-bus", hatch_fluid = "fh-1",
      bus_type = "transposer", transposer_address = "tp-bus",
    },
  },
  vault_address = "tp-bus",
  vault_inventory = { { name = "gregtech:gt.integrated_circuit", damage = 14, size = 4 } },
})
mock_tp.component_types["tp-bus"] = "transposer"

local cm_tp = CircuitManager.new({
  config = trans_cfg,
  component = mock_tp.component,
  component_types = mock_tp.component_types,
})
local ok_tp, err_tp = cm_tp:push_circuit("m1", 14)
check("transposer push_circuit ok", ok_tp == true, err_tp)
check("transferItem called on push", mock_tp.stats.transferItem >= 1)

-- recover: put circuit on bus side manually in mock
local tp_proxy = mock_tp.transposers["tp-bus"]
tp_proxy._inv[3] = { { name = "gregtech:gt.integrated_circuit", damage = 14, size = 1 } }
local ok_rec, err_rec = cm_tp:recover_circuit("m1", 14)
check("transposer recover_circuit ok", ok_rec == true, err_rec)
check("transferItem called on recover", mock_tp.stats.transferItem >= 2)

--------------------------------------------------------------------------------
-- routing auto
--------------------------------------------------------------------------------

check("auto route me_exportbus",
  cm_export:resolve_route(Config.machines[1]) == "export_bus")
check("auto route transposer",
  cm_tp:resolve_route(trans_cfg.machines[1]) == "transposer")

--------------------------------------------------------------------------------
-- broker_core integration
--------------------------------------------------------------------------------

BrokerCore.set_deps(nil)
local poll_fault = MachinePoll.new({ config = Config, component = mock4.component })
local results_fault = poll_fault:poll_all()
local ok_batch = BrokerCore.process_batch("molten_soldering_alloy", 14400, nil, {
  machine_poll = poll_fault,
  poll_results = results_fault,
  push_circuits = false,
})
check("broker_core with faulted pool returns true", ok_batch == true)

-- verify redistribution: only 3 machines get ops summing to 10
local active3 = poll_fault:build_active_pool(results_fault)
local dist3 = LoadBalancer.calculate_distribution(active3, 14400, 1440)
local sum3 = 0
for _, m in ipairs(active3) do
  sum3 = sum3 + dist3[m.id].operations
end
check("fault pool total ops still 10", sum3 == 10)

BrokerCore.set_deps(nil)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

io.write(string.rep("-", 60) .. "\n")
io.write(bold(string.format("Results: %d passed, %d failed\n", passed, failed)))

if failed > 0 then
  os.exit(1)
end
