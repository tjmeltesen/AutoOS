#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/job_assigner_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "tasks" .. sep .. "?.lua",
  package.path,
}, ";")

local LaneState = require("lane_state")
local LockManager = require("lock_manager")
local JobDescriptor = require("job_descriptor")
local JobAssigner = require("job_assigner")

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

-- Minimal machine selector stub
local function make_selector(opts)
  opts = opts or {}
  local available = opts.available or {}
  local budget = opts.budget
  if budget == nil then budget = #available end
  local idx = 0
  return {
    available_budget = function(self, lanes)
      if budget ~= nil then return budget end
      local count = 0
      for _, m in ipairs(available) do
        local lane = lanes[m.id]
        if not lane or LaneState.is_idle(lane) then count = count + 1 end
      end
      return count
    end,
    find_available = function(self, machines, poll_results, lanes, do_rr, filter)
      for i = 1, #available do
        idx = idx + 1
        if idx > #available then idx = 1 end
        local m = available[idx]
        local pr = poll_results[m.id]
        local lane = lanes[m.id]
        local is_idle = not lane or LaneState.is_idle(lane)
        local is_healthy = not pr or pr.healthy ~= false
        if is_idle and is_healthy then
          return m, idx
        end
      end
      return nil
    end,
    advance = function(self, i, machines, do_rr) end,
  }
end

local function make_config(machines, opts)
  opts = opts or {}
  return {
    machines = machines,
    completion_timeout_s = opts.completion_timeout_s or 60,
    staging_timeout_s = opts.staging_timeout_s or 60,
    do_round_robin = opts.do_round_robin ~= false,
    input_mode = opts.input_mode or "per_lane",
  }
end

io.write("\n" .. bold("JobAssigner Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  -- Successful assignment
  local machines = {
    { id = "machine_01", interface_address = "uuid-ae", item_transposer_address = "uuid-tp" },
  }
  local poll_results = { machine_01 = { healthy = true, active = true } }
  local selector = make_selector({ available = machines })
  local lm = LockManager.new()
  local lanes = {}
  local config = make_config(machines)
  local now_fn = function() return 100 end

  local pending_jobs = { JobDescriptor.create({ recipe_key = "item:ingotIron" }, "central", "job_001") }

  local result = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, config, nil, now_fn)
  check("one job assigned", #result.jobs_assigned == 1)
  check("job status is running", pending_jobs[1].status == "running")
  check("job machine_id set", pending_jobs[1].machine_id == "machine_01")
  check("job started_at set", pending_jobs[1].started_at == 100)
  check("lane created and working", LaneState.is_working(lanes["machine_01"]))
end

do
  -- No available machines (all FAULTED)
  local machines = {
    { id = "machine_01", interface_address = "uuid-ae", item_transposer_address = "uuid-tp" },
  }
  local selector = make_selector({ available = {} })  -- none available
  local lm = LockManager.new()
  local lanes = {}
  local config = make_config(machines)
  local pending_jobs = { JobDescriptor.create({}, "central", "job_001") }

  local result = JobAssigner.assign(pending_jobs, {}, selector, lm, lanes, config, nil, function() return 100 end)
  check("no machines yields zero assignments", #result.jobs_assigned == 0)
  check("job remains pending", pending_jobs[1].status == "pending")
end

do
  -- Multiple pending jobs: all eligible get dispatched up to budget
  local machines = {
    { id = "machine_01", interface_address = "uuid-ae-1", item_transposer_address = "uuid-tp-1" },
    { id = "machine_02", interface_address = "uuid-ae-2", item_transposer_address = "uuid-tp-2" },
  }
  local poll_results = {
    machine_01 = { healthy = true, active = true },
    machine_02 = { healthy = true, active = true },
  }
  local selector = make_selector({ available = machines, budget = 2 })
  local lm = LockManager.new()
  local lanes = {}
  local config = make_config(machines)

  local pending_jobs = {
    JobDescriptor.create({}, "central", "job_001"),
    JobDescriptor.create({}, "central", "job_002"),
  }

  local result = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, config, nil, function() return 100 end)
  check("two jobs assigned to two machines", #result.jobs_assigned == 2)
  check("both jobs running", pending_jobs[1].status == "running" and pending_jobs[2].status == "running")
  check("distinct machines assigned", pending_jobs[1].machine_id ~= pending_jobs[2].machine_id)
end

do
  -- Budget enforcement
  local machines = {
    { id = "machine_01", interface_address = "uuid-ae", item_transposer_address = "uuid-tp" },
  }
  local selector = make_selector({ available = machines, budget = 0 })
  local lm = LockManager.new()
  local lanes = {}
  local config = make_config(machines)

  local pending_jobs = {
    JobDescriptor.create({}, "central", "job_001"),
    JobDescriptor.create({}, "central", "job_002"),
  }

  local result = JobAssigner.assign(pending_jobs, {}, selector, lm, lanes, config, nil, function() return 100 end)
  check("zero budget blocks assignment", #result.jobs_assigned == 0)
end

do
  -- Non-pending jobs skipped
  local machines = {
    { id = "machine_01", interface_address = "uuid-ae", item_transposer_address = "uuid-tp" },
  }
  local poll_results = { machine_01 = { healthy = true, active = true } }
  local selector = make_selector({ available = machines })
  local lm = LockManager.new()
  local lanes = {}
  local config = make_config(machines)

  local job2 = JobDescriptor.create({}, "central", "job_002")
  job2.status = "running"

  local pending_jobs = {
    JobDescriptor.create({}, "central", "job_001"),
    job2,
  }

  local result = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, config, nil, function() return 100 end)
  check("skips non-pending job", #result.jobs_assigned == 1)
  check("assigns pending job 1", pending_jobs[1].status == "running")
  check("running job 2 untouched", pending_jobs[2].status == "running")
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("JobAssigner result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
