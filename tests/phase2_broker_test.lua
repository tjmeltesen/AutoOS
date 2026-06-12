#!/usr/bin/env lua
--[[
  AutoOS — Phase 2 broker desktop tests (machine_poll + lane execution)

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
  for i, v in ipairs(a) do if a[i] ~= b[i] then return false end end
  return true
end

io.write("\n" .. bold("AutoOS Phase 2 — Lane Hardware Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

check("Problems: 0 healthy", not MaintenanceParse.has_fault({ "Problems: 0 Efficiency: 100.0 %" }))
check("Problems: 1 fault", MaintenanceParse.has_fault({ "Problems: 1" }))

local mock4 = Mock.new({
  machines = Mock.machines_from_config(Config),
  database_address = Config.database_address,
})
local poll4 = MachinePoll.new({ config = Config, component = mock4.component })
check("4 healthy → pool of 4", #poll4:build_active_pool(poll4:poll_all()) == 4)

mock4.set_machine_fault("machine_02", true)
local pool3 = poll4:build_active_pool(poll4:poll_all())
check("fault machine_02 → pool of 3", #pool3 == 3)

local list_safe = {}
local map_safe = LoadBalancer.calculate_distribution(pool3, 14400, 1440)
for _, m in ipairs(pool3) do list_safe[#list_safe + 1] = map_safe[m.id].operations end
check("safe failure 4,3,3", lists_equal(list_safe, { 4, 3, 3 }), table.concat(list_safe, ","))

local alloc = map_safe.machine_01
local row = Config.machines[1]
local cm = CircuitManager.new({ config = Config, component = mock4.component })
local ok_push, push_err = cm:push_circuit("machine_01", 14)
check("push_circuit ok", ok_push == true, push_err)
check("dynamic descriptor store", mock4.stats.store >= 1)
check("setInterfaceConfiguration called", mock4.stats.setInterfaceConfiguration >= 2)

mock4.transposers[Config.machines[1].transposer_address]._inv[Config.machines[1].push_side] = {
  { name = "gregtech:gt.integrated_circuit", damage = 14, size = 1 },
}
local ok_rec, rec_err = cm:recover_circuit("machine_01", 14)
check("recover_circuit ok", ok_rec == true, rec_err)
check("transferItem on recover", mock4.stats.transferItem >= 2)

local ok_lane = BrokerCore.execute_lane(row, alloc, "molten_soldering_alloy", mock4.component, {
  push_circuits = false,
})
check("execute_lane fluid ok", ok_lane == true)
check("setFluidInterfaceConfiguration called", mock4.stats.setFluidInterfaceConfiguration >= 2)
check("transferFluid called", mock4.stats.transferFluid >= 1)
local tp = mock4.transposers[Config.machines[1].transposer_address]
local fs = tp._last_fluid_sides
local fpull = row.fluid_pull_side or row.pull_side
check("fluid uses fluid_pull/fluid_push sides", fs and fs[1] == fpull and fs[2] == row.fluid_push_side,
  fs and (tostring(fs[1]) .. "→" .. tostring(fs[2])) or "nil")

local tp_inv = mock4.transposers[Config.machines[1].transposer_address]._inv
tp_inv[row.push_side] = {}
tp_inv[row.pull_side] = {}
local ok_full, full_err = BrokerCore.execute_lane(row, alloc, "molten_soldering_alloy", mock4.component, {
  push_circuits = true,
  recover_circuits = true,
  circuit_manager = cm,
})
check("execute_lane circuit+fluid+recover", ok_full == true, full_err)

BrokerCore.set_deps({ component = mock4.component })
check("process_batch with hardware",
  BrokerCore.process_batch("molten_soldering_alloy", 14400, pool3, {
    execute_hardware = true,
    component = mock4.component,
  }) == true)

io.write(string.rep("-", 60) .. "\n")
io.write(bold(string.format("Results: %d passed, %d failed\n", passed, failed)))
if failed > 0 then os.exit(1) end
