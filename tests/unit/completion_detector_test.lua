#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/completion_detector_test.lua"
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
local CompletionDetector = require("completion_detector")

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

io.write("\n" .. bold("CompletionDetector Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001")
  local pending_jobs = { JobDescriptor.create({}, "central", "job_001") }
  pending_jobs[1].status = "running"

  local released_locks
  local release_fn = function(mid, l) released_locks = l end

  local results = { machine_01 = { status = "done" } }
  local lanes = { machine_01 = lane }
  CompletionDetector.poll(results, lanes, pending_jobs, release_fn)
  check("done result transitions to IDLE", LaneState.is_idle(lane))
  check("done sets job status done", pending_jobs[1].status == "done")
  check("done releases locks", released_locks ~= nil)
  check("done consumes result", results["machine_01"] == nil)
end

do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001")
  local pending_jobs = { JobDescriptor.create({}, "central", "job_001") }
  pending_jobs[1].status = "running"

  local released_locks
  local release_fn = function(mid, l) released_locks = l end

  local results = { machine_01 = { status = "failed", error = "LaneWorker: stocking failed" } }
  local lanes = { machine_01 = lane }
  CompletionDetector.poll(results, lanes, pending_jobs, release_fn)
  check("failed result transitions to FAULTED", LaneState.is_faulted(lane))
  check("failed sets job status failed", pending_jobs[1].status == "failed")
  check("failed records error", lane.last_error ~= nil)
  check("failed releases locks", released_locks ~= nil)
end

do
  -- Only WORKING lanes are polled
  local idle_lane = LaneState.create("machine_01")
  local faulted_lane = LaneState.create("machine_02")
  LaneState.assign(faulted_lane, "job_099")
  LaneState.fault(faulted_lane, "prior fault")

  local results = {
    machine_01 = { status = "done" },
    machine_02 = { status = "done" },
  }
  local lanes = { machine_01 = idle_lane, machine_02 = faulted_lane }
  local pending_jobs = {}
  local release_fn = function() error("should not fire") end
  CompletionDetector.poll(results, lanes, pending_jobs, release_fn)
  check("non-working lanes are skipped", LaneState.is_idle(idle_lane) and LaneState.is_faulted(faulted_lane))
end

do
  -- No results means no transitions
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001")
  local lanes = { machine_01 = lane }
  local pending_jobs = {}
  local release_fn = function() error("should not fire") end
  CompletionDetector.poll({}, lanes, pending_jobs, release_fn)
  check("empty results table is safe", LaneState.is_working(lane))
end

do
  -- Multiple completions in one poll pass
  local lane1 = LaneState.create("machine_01")
  local lane2 = LaneState.create("machine_02")
  LaneState.assign(lane1, "job_001")
  LaneState.assign(lane2, "job_002")
  local pending_jobs = {
    JobDescriptor.create({}, "central", "job_001"),
    JobDescriptor.create({}, "central", "job_002"),
  }
  pending_jobs[1].status = "running"
  pending_jobs[2].status = "running"

  local results = {
    machine_01 = { status = "done" },
    machine_02 = { status = "failed", error = "timeout" },
  }
  local lanes = { machine_01 = lane1, machine_02 = lane2 }
  CompletionDetector.poll(results, lanes, pending_jobs, function() end)
  check("multi-completion: done lane idle", LaneState.is_idle(lane1))
  check("multi-completion: failed lane faulted", LaneState.is_faulted(lane2))
  check("multi-completion: done job status", pending_jobs[1].status == "done")
  check("multi-completion: failed job status", pending_jobs[2].status == "failed")
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("CompletionDetector result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
