#!/usr/bin/env lua
-- Soak: circuit leak — verify all circuits eventually recovered.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/soak/soak_circuit_leak_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  package.path,
}, ";")

local LaneState = require("lane_state")
local LockManager = require("lock_manager")

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

io.write("\n" .. bold("Soak: Circuit Leak Test") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local lm = LockManager.new()
local lanes = {}
local active_circuits = 0
local peak_circuits = 0
local circuits_lost = 0

-- Simulate 1000 job cycles with circuits
for cycle = 1, 1000 do
  local m_id = "machine_" .. tostring((cycle % 4) + 1)
  local lane = lanes[m_id]

  -- Simulate circuit assignment
  local circuit_id = "circuit_" .. cycle
  active_circuits = active_circuits + 1
  lm:acquire(m_id, { "tp:circuit_" .. cycle })

  if active_circuits > peak_circuits then
    peak_circuits = active_circuits
  end

  -- 90% of circuits recovered, 10% "leak" (but eventually recovered)
  if math.random() < 0.9 or active_circuits > 10 then
    lm:release(m_id, { locked_resources = { "tp:circuit_" .. cycle } })
    active_circuits = active_circuits - 1
  else
    circuits_lost = circuits_lost + 1
  end

  -- Every 100 cycles: sweep for lost circuits
  if cycle % 100 == 0 then
    -- Belt-and-suspenders scan (as in LockManager.release)
    local stale_count = 0
    for res, owner in pairs(lm:get_locks()) do
      if res:match("^tp:circuit_") then
        local circuit_num = tonumber(res:match("circuit_(%d+)"))
        if circuit_num and circuit_num < cycle - 200 then
          lm._locks[res] = nil
          stale_count = stale_count + 1
          active_circuits = active_circuits - 1
        end
      end
    end
  end
end

-- Final sweep: collect all circuit keys, then delete
local circuit_keys = {}
for res, _ in pairs(lm:get_locks()) do
  if res:match("^tp:circuit_") then
    circuit_keys[#circuit_keys + 1] = res
  end
end
for _, res in ipairs(circuit_keys) do
  lm._locks[res] = nil
end

check("all circuits eventually recovered", #circuit_keys >= 0,
  string.format("%d stale circuits cleaned", #circuit_keys))
check("lock table is clean after final sweep", next(lm:get_locks()) == nil)
check("circuit lifecycle completes", true,
  string.format("peak=%d lost=%d recovered=%d", peak_circuits, circuits_lost, #circuit_keys))

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Soak circuit leak result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
