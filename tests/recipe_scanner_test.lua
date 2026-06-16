#!/usr/bin/env lua
--[[
  AutoOS — AE pattern scanner desktop tests

  Run: lua55 tests\recipe_scanner_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/recipe_scanner_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "orchestrator" .. sep .. "?.lua",
  package.path,
}, ";")

local RecipeScanner = require("demoted.recipe_scanner")
local BrokerRegistry = require("demoted.broker_registry")
local Registry = require("demoted.ae_recipe_registry")
local BrokerConfig = require("config")
local OrchConfig = require("orchestrator_config")

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

io.write("\n" .. bold("AutoOS — Recipe Scanner Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local function mock_me(craftables_by_label, fluids)
  return {
    getFluidsInNetwork = function()
      local out = {}
      for label, amount in pairs(fluids or {}) do
        out[#out + 1] = { label = label, amount = amount }
      end
      return out
    end,
    getCraftables = function(filter)
      local label = filter and filter.label
      if not label then return {} end
      label = label:gsub("^drop of ", "")
      local list = craftables_by_label[label]
      if not list then return {} end
      local out = {}
      for _, row in ipairs(list) do
        out[#out + 1] = {
          getItemStack = function() return { label = row.label, name = row.name } end,
        }
      end
      return out
    end,
  }
end

-- Broker registry: discover new pattern from subnet fluids --------------------
do
  local registry = BrokerRegistry.new(BrokerConfig)
  registry:seed_from_config()
  local me = mock_me({
    Propylene = { { label = "Propylene" } },
  }, { Propylene = 5000 })

  local added, updated = RecipeScanner.scan(me, registry, {
    config = BrokerConfig, now = 42,
  })
  check("discovers new fluid pattern", added == 1, added)
  check("registry row exists", registry.entries.propylene ~= nil)
  check("auto-allocates uid", registry.entries.propylene.recipe_uid == 258,
    registry.entries.propylene and registry.entries.propylene.recipe_uid)
  check("marks ae_scan source", registry.entries.propylene.source == "ae_scan")
  check("update not add on rescan", (function()
    local a, u = RecipeScanner.scan(me, registry, { config = BrokerConfig, now = 43 })
    return a == 0 and u == 1
  end)(), updated)
end

-- Config seed wins on fluid_requirement / circuit_damage ----------------------
do
  local registry = BrokerRegistry.new(BrokerConfig)
  registry:seed_from_config()
  local me = mock_me({
    Ethylene = { { label = "Ethylene" } },
  }, { Ethylene = 1000 })

  RecipeScanner.scan(me, registry, { config = BrokerConfig, now = 1 })
  local row = registry.entries.polyethylene
  check("config seed preserved for polyethylene", row ~= nil)
  check("config circuit_damage kept", row and row.circuit_damage == 18, row and row.circuit_damage)
  check("config fluid_requirement kept", row and row.fluid_requirement == 1000, row and row.fluid_requirement)
end

-- Orchestrator registry reads pattern_scan from orchestrator block ------------
do
  local registry = Registry.new({ config = OrchConfig })
  registry:seed_from_config()
  local me = mock_me({
    ["Molten Tin"] = { { label = "Molten Tin" } },
  }, { ["Molten Tin"] = 2000 })

  local added = RecipeScanner.scan(me, registry, { config = OrchConfig, now = 5 })
  check("orchestrator registry scan", added == 1, added)
  check("slug recipe_key", registry.entries.molten_tin ~= nil)
end

-- extra_labels seed when no fluids on network ---------------------------------
do
  local registry = BrokerRegistry.new(BrokerConfig)
  registry:seed_from_config()
  local me = mock_me({
    Styrene = { { label = "Styrene" } },
  }, {})

  local added = RecipeScanner.scan(me, registry, {
    config = BrokerConfig,
    extra_labels = { "Styrene" },
    now = 7,
  })
  check("extra_labels discovers pattern", added == 1, added)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Scanner result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
