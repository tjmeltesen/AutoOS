#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "universal/tests/dispatcher_test.lua"
local tests_dir = script:match("^(.*)[/\\]") or "universal/tests"
local universal_root = tests_dir .. sep .. ".."
local project_root = universal_root .. sep .. ".."
package.path = table.concat({
  universal_root .. sep .. "?.lua",
  tests_dir .. sep .. "?.lua",
  project_root .. sep .. "?.lua",
  package.path,
}, ";")

local H = require("test_harness")
local Dispatcher = require("broker.dispatcher")

H.summary("Universal — capability dispatcher")

local multis = {
  {
    id = "dist_tower_a",
    capabilities = { "distillation_tower" },
    installed_tools = { "Circuit24", "TowerMold" },
  },
  {
    id = "dist_tower_b",
    capabilities = { "distillation_tower" },
    installed_tools = { "Circuit25", "TowerMold" },
  },
  {
    id = "chem_reactor_1",
    capabilities = { "chemical_reactor" },
    installed_tools = { "Circuit6" },
  },
}

local function cache_for(states)
  local machines = {}
  for id, st in pairs(states) do
    machines[id] = st
  end
  return { machines = machines }
end

local idle = { available = true, active = false, has_work = false, maintenance_fault = false }
local busy = { available = true, active = true, has_work = true, maintenance_fault = false }
local fault = { available = true, active = false, has_work = false, maintenance_fault = true }

local id_a, err = Dispatcher.pick("Benzene", multis, cache_for({ dist_tower_a = idle, dist_tower_b = idle }))
H.check("Benzene -> Tower A (FIFO)", id_a == "dist_tower_a", err)

id_a, err = Dispatcher.pick("Benzene", multis, cache_for({ dist_tower_a = busy, dist_tower_b = idle }))
H.check("Benzene busy A, B lacks Circuit24 -> none",
  id_a == nil and err == "no_available_machine")

id_a = Dispatcher.pick("Toluene", multis, cache_for({ dist_tower_a = busy, dist_tower_b = idle }))
H.check("Toluene busy A -> Tower B", id_a == "dist_tower_b")

id_a = Dispatcher.pick("Toluene", multis, cache_for({ dist_tower_a = idle, dist_tower_b = idle }))
H.check("Toluene -> Tower B (Circuit25)", id_a == "dist_tower_b")

id_a = Dispatcher.pick("SulfuricAcid", multis, cache_for({ chem_reactor_1 = idle }))
H.check("SulfuricAcid -> chem reactor", id_a == "chem_reactor_1")

id_a, err = Dispatcher.pick("Benzene", multis, cache_for({ dist_tower_a = fault, dist_tower_b = busy }))
H.check("no available machine", id_a == nil and err == "no_available_machine")

id_a, err = Dispatcher.pick("UnknownProduct", multis, cache_for({ dist_tower_a = idle }))
H.check("unknown recipe", id_a == nil and err == "unknown_recipe")

os.exit(H.report() and 0 or 1)
