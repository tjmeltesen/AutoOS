#!/usr/bin/env lua

-- circuit_manager requires OC `component` API and HW module — test its core helpers
-- (stack matching, transfer result parsing) without requiring full mock hardware.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/circuit_manager_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  package.path,
}, ";")

-- Load the CircuitManager module to validate its API surface and public methods
local CircuitManager = require("circuit_manager")

local ESC = string.char(27)
local function color(c, t) return ESC .. "[" .. c .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write("  -  " .. tostring(detail)) end
  io.write("\n")
end

io.write("\n" .. bold("CircuitManager Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- Module structure
do
  check("CircuitManager is a table", type(CircuitManager) == "table")
  check("CircuitManager has new()", type(CircuitManager.new) == "function")
  check("CircuitManager has stack_is_circuit", type(CircuitManager.stack_is_circuit) == "function")
  check("CircuitManager has find_circuit_slot", type(CircuitManager.find_circuit_slot) == "function")
  check("CircuitManager has transfer_one", type(CircuitManager.transfer_one) == "function")
  check("CircuitManager has scan_transposer", type(CircuitManager.scan_transposer) == "function")
  check("CircuitManager has describe_face", type(CircuitManager.describe_face) == "function")
end

-- Construction
do
  local cm = CircuitManager.new({
    config = {
      machines = {},
      circuit_item_name = "gregtech:gt.integrated_circuit",
    },
    component = {
      proxy = function() return {} end,
    },
    yield_sleep = function() end,
  })
  check("new returns instance", type(cm) == "table")
  check("new sets metatable __index", getmetatable(cm).__index == CircuitManager)
end

-- Construction requires config
do
  local ok, err = pcall(CircuitManager.new, {})
  check("new fails without config", ok == false)
end

-- Construction with custom circuit item name
do
  local cm = CircuitManager.new({
    config = {
      machines = {},
      circuit_item_name = "custom:my_circuit",
    },
    component = { proxy = function() return {} end },
  })
  check("custom circuit_item_name stored", cm.circuit_item == "custom:my_circuit")
end

-- stack_is_circuit
do
  local cm = CircuitManager.new({
    config = { machines = {}, circuit_item_name = "gregtech:gt.integrated_circuit" },
    component = { proxy = function() return {} end },
  })

  check("stack_is_circuit: exact match",
    cm:stack_is_circuit({ name = "gregtech:gt.integrated_circuit", damage = 5, size = 1 }))
  check("stack_is_circuit: substring match",
    cm:stack_is_circuit({ name = "gregtech:gt.metaitem.01:integrated_circuit:5", damage = 5, size = 1 }))
  check("stack_is_circuit: nil input",
    not cm:stack_is_circuit(nil))
  check("stack_is_circuit: non-table input",
    not cm:stack_is_circuit("not a stack"))
  check("stack_is_circuit: wrong item",
    not cm:stack_is_circuit({ name = "minecraft:stone", damage = 0, size = 1 }))
  check("stack_is_circuit: no damage filter with nil",
    cm:stack_is_circuit({ name = "gregtech:gt.integrated_circuit", damage = 5, size = 1 }, nil))
  check("stack_is_circuit: damage mismatch",
    not cm:stack_is_circuit({ name = "gregtech:gt.integrated_circuit", damage = 5, size = 1 }, 3))
  check("stack_is_circuit: damage match",
    cm:stack_is_circuit({ name = "gregtech:gt.integrated_circuit", damage = 7, size = 1 }, 7))
end

do
  -- scan_transposer with bad machine_id
  local cm = CircuitManager.new({
    config = { machines = { { id = "machine_01" } } },
    component = { proxy = function() return {} end },
  })
  local _, scan_err = cm:scan_transposer("nonexistent", "item")
  check("scan_transposer returns error for unknown machine", scan_err ~= nil)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("CircuitManager result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
