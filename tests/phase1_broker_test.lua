#!/usr/bin/env lua
--[[
  AutoOS — Phase 1 broker desktop tests (config + load balancer)

  Run: C:\Lua\lua55.exe tests\phase1_broker_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/phase1_broker_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local Config = require("config")
local LoadBalancer = require("load_balancer")
local BrokerCore = require("broker_core")

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

local function ops_in_order(pool, volume, unit)
  local map, err = LoadBalancer.calculate_distribution(pool, volume, unit)
  if not map then return nil, err end
  local list = {}
  for _, m in ipairs(pool) do list[#list + 1] = map[m.id].operations end
  return list, map
end

io.write("\n" .. bold("AutoOS Phase 1 — Config & Load Balancer Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

check("Config.validate passes on default template", Config.validate(Config) == true)

local dup_cfg = {
  database_address = "db",
  machines = {
    { id = "a", gt_address = "1", interface_address = "i1", transposer_address = "t1", item_bus_side = 0, fluid_push_side = 2 },
    { id = "a", gt_address = "2", interface_address = "i2", transposer_address = "t2", item_bus_side = 0, fluid_push_side = 2 },
  },
  constraints = { recipe_baselines = { x = { fluid_requirement = 100, fluid_label = "Test Fluid" } } },
}
check("duplicate id rejected", select(1, Config.validate(dup_cfg)) == nil)

local miss_cfg = {
  database_address = "db",
  machines = { { id = "a", gt_address = "1", interface_address = "i", transposer_address = "t", item_bus_side = 0 } },
  constraints = { recipe_baselines = { x = { fluid_requirement = 100, fluid_label = "Test Fluid" } } },
}
check("missing item_bus_side rejected", select(1, Config.validate(miss_cfg)) == nil)

local miss_fluid = {
  database_address = "db",
  machines = { { id = "a", gt_address = "1", interface_address = "i", transposer_address = "t", pull_side = 0, push_side = 3 } },
  constraints = { recipe_baselines = { x = { fluid_requirement = 100, fluid_label = "Test Fluid" } } },
}
check("missing fluid_push_side rejected", select(1, Config.validate(miss_fluid)) == nil)

check("total_operations 15000/1440 = 10", LoadBalancer.total_operations(15000, 1440) == 10)

local pool4 = Config.machines
local list_a = ops_in_order(pool4, 15000, 1440)
check("15000L/1440 → 3,3,2,2", lists_equal(list_a, { 3, 3, 2, 2 }), table.concat(list_a or {}, ","))

local list_b = ops_in_order(pool4, 3000, 1000)
check("3000L/1000 → 1,1,1,0", lists_equal(list_b, { 1, 1, 1, 0 }), table.concat(list_b or {}, ","))

local pool3 = { Config.machines[1], Config.machines[2], Config.machines[3] }
local list_d = ops_in_order(pool3, 14400, 1440)
check("14400L/1440/3 lanes → 4,3,3", lists_equal(list_d, { 4, 3, 3 }), table.concat(list_d or {}, ","))

local map_a = LoadBalancer.calculate_distribution(pool4, 15000, 1440)
check("allocation has interface_address", map_a and map_a.machine_01 and map_a.machine_01.interface_address ~= nil)

check("empty pool error", select(1, LoadBalancer.calculate_distribution({}, 15000, 1440)) == nil)
check("short batch error", select(1, LoadBalancer.calculate_distribution(pool4, 500, 1440)) == nil)

BrokerCore.set_deps({})
BrokerCore.reset_descriptor_cache()
check("process_batch print-only (no component)", BrokerCore.process_batch("molten_soldering_alloy", 15000, Config.machines, { execute_hardware = false }) == true)
check("process_batch 500L halted", BrokerCore.process_batch("molten_soldering_alloy", 500, Config.machines, { execute_hardware = false }) == false)

io.write(string.rep("-", 60) .. "\n")
io.write(bold(string.format("Results: %d passed, %d failed\n", passed, failed)))
if failed > 0 then os.exit(1) end
