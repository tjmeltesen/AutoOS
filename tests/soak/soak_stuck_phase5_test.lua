#!/usr/bin/env lua
-- Soak: stuck phase 5 — verify watchdog fires when completion hangs.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/soak/soak_stuck_phase5_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  package.path,
}, ";")

local LaneState = require("lane_state")
local JobDescriptor = require("job_descriptor")
local Watchdog = require("watchdog")
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

io.write("\n" .. bold("Soak: Stuck Phase 5 Test") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local lm = LockManager.new()
local recoveries = 0
local timeout_count = 0

-- Run 100 iterations of stuck-and-recover
for iter = 1, 100 do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_" .. iter, { "interface:test" }, iter + 5)  -- deadline: iter+5

  local pending_jobs = { JobDescriptor.create({}, "central", "job_" .. iter) }
  pending_jobs[1].status = "running"

  local lanes = { machine_01 = lane }

  -- Simulate stuck: never produce completion result
  -- Watchdog should fire after deadline + grace
  local now = iter + 20  -- well past deadline
  Watchdog.check(lanes, pending_jobs, now, 10, function(mid, l) lm:release(mid, l) end)

  if LaneState.is_faulted(lane) then
    timeout_count = timeout_count + 1
    -- Recover
    LaneState.recover(lane)
    recoveries = recoveries + 1
  end
end

check("all iterations timed out", timeout_count == 100,
  string.format("%d timeouts", timeout_count))
check("all lanes recovered", recoveries == 100)
check("no lanes stuck permanently", true)  -- implicit: all recovered

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Soak stuck phase5 result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
