#!/usr/bin/env lua
--[[
  AutoOS — Phase 1 broker desktop test suite (config + load balancer + stub)

  Run from project root:
    C:\Lua\lua55.exe tests\phase1_broker_test.lua
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

local function ops_in_order(pool, volume, unit)
  local map, err = LoadBalancer.calculate_distribution(pool, volume, unit)
  if not map then
    return nil, err
  end
  local list = {}
  for _, m in ipairs(pool) do
    list[#list + 1] = map[m.id].operations
  end
  return list, map
end

local function sum_ops(list)
  local s = 0
  for _, v in ipairs(list) do s = s + v end
  return s
end

local function lists_equal(a, b)
  if #a ~= #b then return false end
  for i, v in ipairs(a) do
    if a[i] ~= b[i] then return false end
  end
  return true
end

io.write("\n" .. bold("AutoOS Phase 1 — Config & Load Balancer Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

--------------------------------------------------------------------------------
-- Config.validate
--------------------------------------------------------------------------------

check("Config.validate passes on default template", Config.validate(Config) == true)

local dup_cfg = {
  machines = {
    { id = "a", gt_address = "1", bus_in = "2", hatch_fluid = "3" },
    { id = "a", gt_address = "4", bus_in = "5", hatch_fluid = "6" },
  },
  constraints = { recipe_baselines = { x = { fluid_requirement = 100 } } },
}
local dup_ok, dup_err = Config.validate(dup_cfg)
check("Config.validate rejects duplicate id", dup_ok == nil and dup_err:find("duplicate"))

local miss_cfg = {
  machines = { { id = "a", gt_address = "1", bus_in = "2" } },
  constraints = { recipe_baselines = { x = { fluid_requirement = 100 } } },
}
local miss_ok, miss_err = Config.validate(miss_cfg)
check("Config.validate rejects missing hatch_fluid", miss_ok == nil and miss_err:find("hatch_fluid"))

local zero_cfg = {
  machines = { { id = "a", gt_address = "1", bus_in = "2", hatch_fluid = "3" } },
  constraints = { recipe_baselines = { x = { fluid_requirement = 0 } } },
}
local zero_ok, zero_err = Config.validate(zero_cfg)
check("Config.validate rejects zero fluid_requirement", zero_ok == nil and zero_err:find("fluid_requirement"))

--------------------------------------------------------------------------------
-- LoadBalancer.total_operations
--------------------------------------------------------------------------------

check("total_operations 15000/1440 = 10", LoadBalancer.total_operations(15000, 1440) == 10)
check("total_operations 3000/1000 = 3", LoadBalancer.total_operations(3000, 1000) == 3)

--------------------------------------------------------------------------------
-- README verification cases
--------------------------------------------------------------------------------

local pool4 = Config.machines

local list_a, map_a = ops_in_order(pool4, 15000, 1440)
check("README 15000L/1440 → 3,3,2,2", lists_equal(list_a, { 3, 3, 2, 2 }), table.concat(list_a or {}, ","))

local list_b, map_b = ops_in_order(pool4, 3000, 1000)
check("Hand-Off 3000L/1000 → 1,1,1,0", lists_equal(list_b, { 1, 1, 1, 0 }), table.concat(list_b or {}, ","))

local pool1 = { Config.machines[1] }
local list_c = ops_in_order(pool1, 5000, 1000)
check("Single machine 5000L/1000 → 5", lists_equal(list_c, { 5 }), table.concat(list_c or {}, ","))

local pool3 = { Config.machines[1], Config.machines[2], Config.machines[3] }
local list_d = ops_in_order(pool3, 14400, 1440) -- 10 ops across 3 machines
check("Reduced pool 14400L/1440 → 4,3,3", lists_equal(list_d, { 4, 3, 3 }), table.concat(list_d or {}, ","))

--------------------------------------------------------------------------------
-- Invariants
--------------------------------------------------------------------------------

if list_a and map_a then
  check("Scenario A sum ops = 10", sum_ops(list_a) == 10)
  for id, row in pairs(map_a) do
    check("Scenario A allocated_volume integer for " .. id,
      row.allocated_volume == row.operations * 1440 and row.allocated_volume % 1440 == 0)
    check("Scenario A has hatch_fluid for " .. id, row.hatch_fluid ~= nil and row.bus_in ~= nil)
  end
end

if list_b and map_b then
  check("Scenario B sum ops = 3", sum_ops(list_b) == 3)
  check("Scenario B reactor_04 has 0 ops", map_b.reactor_04.operations == 0)
  check("Scenario B reactor_04 still in map", map_b.reactor_04 ~= nil)
end

--------------------------------------------------------------------------------
-- Error paths
--------------------------------------------------------------------------------

local empty_map, empty_err = LoadBalancer.calculate_distribution({}, 15000, 1440)
check("Empty pool returns error", empty_map == nil and empty_err == "No operational machines found.")

local short_map, short_err = LoadBalancer.calculate_distribution(pool4, 500, 1440)
check("500L/1440 returns short batch error",
  short_map == nil and short_err == "Batch volume falls short of minimum recipe boundaries.")

local bad_unit, bad_err = LoadBalancer.calculate_distribution(pool4, 15000, 0)
check("Invalid unit requirement", bad_unit == nil and bad_err == "Invalid unit requirement.")

--------------------------------------------------------------------------------
-- Broker stub
--------------------------------------------------------------------------------

check("BrokerCore.process_batch solder 15000 returns true",
  BrokerCore.process_batch("molten_soldering_alloy", 15000) == true)

check("BrokerCore.process_batch 500L returns false",
  BrokerCore.process_batch("molten_soldering_alloy", 500) == false)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

io.write(string.rep("-", 60) .. "\n")
io.write(bold(string.format("Results: %d passed, %d failed\n", passed, failed)))

if failed > 0 then
  os.exit(1)
end
