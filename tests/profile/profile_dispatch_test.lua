#!/usr/bin/env lua
-- Profile: dispatch pipeline phase timings.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/profile/profile_dispatch_test.lua"
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

local ProfileHarness = require("profile_harness")
local LaneState = require("lane_state")
local LockManager = require("lock_manager")
local JobDescriptor = require("job_descriptor")
local CompletionDetector = require("completion_detector")
local Watchdog = require("watchdog")
local JobReaper = require("job_reaper")
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

io.write("\n" .. bold("Profile: Dispatch Pipeline") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local profiler = ProfileHarness.new({ iterations = 50 })

-- Profile a single complete tick cycle
profiler:measure("full_tick", function()
  local lm = LockManager.new()
  local lanes = {}
  local results = {}
  local pending_jobs = {}
  local machines = {
    { id = "m1", interface_address = "iface-1", item_transposer_address = "tp-1" },
    { id = "m2", interface_address = "iface-2", item_transposer_address = "tp-2" },
  }
  local poll_results = { m1 = { healthy = true }, m2 = { healthy = true } }

  -- Create mock selector
  local selector = {
    available_budget = function() return 2 end,
    find_available = function(_, _machines, _pr, _lanes, _do_rr)
      for _, m in ipairs(machines) do
        local lane = lanes[m.id]
        if not lane or LaneState.is_idle(lane) then return m, 1 end
      end
    end,
    advance = function() end,
  }

  local config = { machines = machines, completion_timeout_s = 60, do_round_robin = true }

  -- Phase 1-2: Create + assign
  for i = 1, 2 do
    pending_jobs[i] = JobDescriptor.create({}, "central", "job_" .. i)
  end

  JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, config, nil, function() return 100 end)

  -- Phase 3 (completion): simulate done
  for _, m in ipairs(machines) do
    if lanes[m.id] and LaneState.is_working(lanes[m.id]) then
      results[m.id] = { status = "done" }
    end
  end
  CompletionDetector.poll(results, lanes, pending_jobs, function(mid, l) lm:release(mid, l) end)

  -- Phase 4 (watchdog): check
  Watchdog.check(lanes, pending_jobs, 200, 10, function() end)

  -- Phase 5 (reaper): cleanup
  JobReaper.reap(pending_jobs, 2)
end)

-- Profile individual subsystem costs
profiler:measure("lane_state_ops", function()
  local lane = LaneState.create("m1")
  for _ = 1, 20 do
    LaneState.assign(lane, "j1", { "r1" }, 500)
    LaneState.complete(lane)
  end
end)

profiler:measure("lock_ops", function()
  local lm = LockManager.new()
  for i = 1, 20 do
    lm:acquire("m" .. i, { "interface:uuid-" .. i })
  end
  for i = 1, 20 do
    lm:release("m" .. i, { locked_resources = { "interface:uuid-" .. i } })
  end
end)

check("full_tick measured", profiler.results.full_tick ~= nil)
check("lane_state_ops measured", profiler.results.lane_state_ops ~= nil)
check("lock_ops measured", profiler.results.lock_ops ~= nil)
check("all timings valid", profiler.results.full_tick.mean > 0)

-- Save report
local report_dir = here .. sep .. "reports"
os.execute('mkdir "' .. report_dir .. '" 2>NUL')
profiler:save_report(report_dir .. sep .. "profile_dispatch.csv")
print("\n" .. profiler:report())

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Profile dispatch result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
