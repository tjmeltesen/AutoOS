#!/usr/bin/env lua
-- Full lane stack: end-to-end execution from manifest to completion.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/integration/full_lane_stack_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "shared" .. sep .. "?.lua",
  package.path,
}, ";")

local Config = require("config")
local MockHardware = require("mock_broker_hardware")
local JobDescriptor = require("job_descriptor")
local JobAssigner = require("job_assigner")
local LockManager = require("lock_manager")
local LaneState = require("lane_state")
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

io.write("\n" .. bold("Full Lane Stack Integration Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  -- Setup: create mock hardware, build a job, assign, and complete
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local now_fn = function() return 100 end

  local pending_jobs = {}
  local results = {}

  -- Create a mock manifest (a simple recipe)
  local manifest = {
    recipe_uid = 1,
    recipe_key = "item:ingotIron",
    items = {},
    fluids = {},
    volume_mB = 144000,
    circuit_number = 1,
  }

  local job = JobDescriptor.create(manifest, "central", "test_job_001", now_fn())
  table.insert(pending_jobs, job)
  check("job created and pending", job.status == "pending")

  -- Build poll results: all machines healthy
  local poll_results = {}
  for _, m in ipairs(Config.machines) do
    poll_results[m.id] = { healthy = true, active = true }
  end

  -- Create mock machine selector (ponytail: MachineSelector.new requires OC hardware)
  local selector = {
    available_budget = function() return #Config.machines end,
    find_available = function(self, machines, pr, lane_map, do_rr)
      for _, m in ipairs(machines) do
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, 1 end
      end
    end,
    advance = function() end,
  }

  -- Assign job
  local result = JobAssigner.assign(
    pending_jobs, poll_results, selector, lm, lanes, Config, nil, now_fn)
  check("job assigned", #result.jobs_assigned >= 1)

  if #result.jobs_assigned >= 1 then
    local assigned_machine = result.jobs_assigned[1]
    check("job status is running", job.status == "running")
    check("job has machine_id", job.machine_id == assigned_machine)
    check("lane is WORKING", LaneState.is_working(lanes[assigned_machine]))
  end

  -- Simulate completion via results table
  if job.machine_id then
    results[job.machine_id] = { status = "done" }
    CompletionDetector.poll(results, lanes, pending_jobs, function(mid, l) lm:release(mid, l) end)
    check("job completed (done status)", job.status == "done")
  end
end

do
  -- Simulate job failure and retry
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local now_fn = function() return 200 end

  local pending_jobs = {}
  local results = {}

  local manifest = {
    recipe_uid = 2,
    recipe_key = "item:ingotGold",
    items = {},
    fluids = {},
    volume_mB = 144000,
    circuit_number = 2,
  }

  local job = JobDescriptor.create(manifest, "central", "test_job_002", now_fn())
  table.insert(pending_jobs, job)

  local poll_results = {}
  for _, m in ipairs(Config.machines) do
    poll_results[m.id] = { healthy = true, active = true }
  end

  local selector = {
    available_budget = function() return #Config.machines end,
    find_available = function(self, machines, pr, lane_map, do_rr)
      for _, m in ipairs(machines) do
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, 1 end
      end
    end,
    advance = function() end,
  }
  JobAssigner.assign(
    pending_jobs, poll_results, selector, lm, lanes, Config, nil, now_fn)

  if job.machine_id then
    -- Simulate failure
    results[job.machine_id] = { status = "failed", error = "LaneWorker: stocking failed" }
    CompletionDetector.poll(results, lanes, pending_jobs, function(mid, l) lm:release(mid, l) end)
    check("job failed status set", job.status == "failed")
    check("lane faulted", LaneState.is_faulted(lanes[job.machine_id]))
  end
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Full lane stack result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
