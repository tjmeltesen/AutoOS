#!/usr/bin/env lua
--[[
  AutoOS — fluid_tanks helper tests

  Run: lua55 tests\fluid_tanks_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/fluid_tanks_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local FluidTanks = require("fluid_tanks")

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

do
  local dev = {
    getTankLevel = function(side) return side == 1 and 900 or 0 end,
  }
  check("tank_level supports getTankLevel(side)", FluidTanks.tank_level(dev, 1) == 900)
end

do
  local dev = {
    getFluidInTank = function(side)
      if side ~= 2 then return {} end
      return {
        { name = "oxygen", amount = 7000 },
        { name = "ethylene", amount = 1000 },
      }
    end,
  }
  local rows = FluidTanks.non_empty_tanks(dev, 2)
  check("non_empty_tanks returns both rows", #rows == 2)
  check("tank_level aggregates getFluidInTank", FluidTanks.tank_level(dev, 2) == 8000)
end

do
  check("label_matches ignores fluid prefixes",
    FluidTanks.label_matches("drop of molten oxygen", "oxygen"))
  check("buffer_empty true at zero",
    FluidTanks.buffer_empty({ getTankLevel = function() return 0 end }, 0))
end

io.write("\n" .. bold("AutoOS Fluid Tanks Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Fluid tanks result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
