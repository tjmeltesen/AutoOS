#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/watchdog_test.lua"
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

io.write("\n" .. bold("Watchdog Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001", { "res1" }, 100)
  local pending_jobs = { JobDescriptor.create({}, "central", "job_001") }
  pending_jobs[1].status = "running"

  local release_fn = function(mid, l) end

  local lanes = { machine_01 = lane }
  Watchdog.check(lanes, pending_jobs, 95, 10, release_fn)
  check("within deadline not faulted", LaneState.is_working(lane))
end

do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001", { "res1" }, 100)
  local pending_jobs = { JobDescriptor.create({}, "central", "job_001") }
  pending_jobs[1].status = "running"

  local released_locks
  local release_fn = function(mid, l) released_locks = l end

  local lanes = { machine_01 = lane }
  Watchdog.check(lanes, pending_jobs, 120, 10, release_fn)
  check("past deadline+grace is faulted", LaneState.is_faulted(lane))
  check("fault records error reason", lane.last_error ~= nil)
  check("fault sets job status failed", pending_jobs[1].status == "failed")
  check("fault releases locks via callback", released_locks ~= nil)
end

do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001", { "res1" }, 100)
  local pending_jobs = { JobDescriptor.create({}, "central", "job_001") }

  local release_fn = function() end
  local lanes = { machine_01 = lane }
  -- At exactly deadline: not yet expired (grace applies)
  Watchdog.check(lanes, pending_jobs, 100, 10, release_fn)
  check("at exact deadline not faulted (grace applies)", LaneState.is_working(lane))
end

do
  -- Grace period extension
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001", { "res1" }, 100)
  local pending_jobs = { JobDescriptor.create({}, "central", "job_001") }
  local release_fn = function() end
  local lanes = { machine_01 = lane }
  -- Within grace: deadline=100, now=105, grace=10 -> not yet
  Watchdog.check(lanes, pending_jobs, 105, 10, release_fn)
  check("within grace period not faulted", LaneState.is_working(lane))
  -- Past grace: deadline=100, now=111, grace=10 -> faulted
  Watchdog.check(lanes, pending_jobs, 111, 10, release_fn)
  check("past grace period is faulted", LaneState.is_faulted(lane))
end

do
  -- Non-WORKING lanes ignored
  local idle_lane = LaneState.create("machine_01")
  local faulted_lane = LaneState.create("machine_02")
  LaneState.assign(faulted_lane, "job_099")
  LaneState.fault(faulted_lane, "prior fault")

  local pending_jobs = {}
  local release_fn = function() error("should not be called") end
  local lanes = { machine_01 = idle_lane, machine_02 = faulted_lane }
  -- Should not crash
  Watchdog.check(lanes, pending_jobs, 999, 10, release_fn)
  check("idle lane ignored", LaneState.is_idle(idle_lane))
  check("faulted lane ignored (stays faulted)", LaneState.is_faulted(faulted_lane))
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Watchdog result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
