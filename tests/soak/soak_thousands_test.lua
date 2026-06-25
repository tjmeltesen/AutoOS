#!/usr/bin/env lua
-- Soak: thousands of dispatch cycles with randomized failures.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/soak/soak_thousands_test.lua"
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

local SoakHarness = require("soak_harness")
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

io.write("\n" .. bold("Soak: Thousands Test") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- Simulate a simplified dispatch loop: create lanes, run jobs, complete them
local harness = SoakHarness.new({
  machines = 4,
  cycles = 5000,
  fault_rate = 0.05,
})

local lm = LockManager.new()
local lanes = {}
local active_jobs = 0
local total_completed = 0

-- Create synthetic machines
local machines = {}
for i = 1, harness.machines do
  local id = "machine_" .. string.format("%02d", i)
  machines[i] = {
    id = id,
    interface_address = "iface-" .. id,
    item_transposer_address = "tp-item-" .. id,
  }
  lanes[id] = LaneState.create(id)
end

-- Simplified dispatch loop
for cycle = 1, harness.cycles do
  harness.stats.cycles = cycle

  -- Assign work to idle lanes
  for _, m in ipairs(machines) do
    local lane = lanes[m.id]
    if LaneState.is_idle(lane) then
      local resources = lm:build_resources(m)
      local ok = lm:acquire(m.id, resources)
      if ok then
        LaneState.assign(lane, "job_" .. cycle .. "_" .. m.id, resources, cycle + 100)
        active_jobs = active_jobs + 1
        harness:record("dispatched")
      end
    end
  end

  -- Complete or fail working lanes
  for _, m in ipairs(machines) do
    local lane = lanes[m.id]
    if LaneState.is_working(lane) then
      -- Check timeout (deadline passed)
      if cycle > lane.deadline + 10 then
        LaneState.fault(lane, "timeout")
        lm:release(m.id, lane)
        harness:record("failed")
        active_jobs = active_jobs - 1
      elseif lane.deadline - cycle <= 1 or harness:should_fault() then
        -- Job finishes (either naturally or via fault injection)
        if harness:should_fault() then
          LaneState.fault(lane, "injected fault")
          lm:release(m.id, lane)
          harness:record("failed")
        else
          LaneState.complete(lane)
          lm:release(m.id, lane)
          harness:record("completed")
          total_completed = total_completed + 1
        end
        active_jobs = active_jobs - 1
      end
    end
    -- Recover faulted lanes
    if LaneState.is_faulted(lane) then
      LaneState.recover(lane)
    end
  end

  harness:update_peak("peak_queue", active_jobs)

  -- Invariant checks every 100 cycles
  if cycle % 100 == 0 then
    harness:check_invariant("no negative active jobs", active_jobs >= 0)
    harness:check_invariant("active jobs bounded", active_jobs <= harness.machines * 2)

    local working_count = 0
    for _, m in ipairs(machines) do
      if LaneState.is_working(lanes[m.id]) then working_count = working_count + 1 end
    end
    harness:check_invariant("working lanes match active", working_count <= active_jobs)
  end
end

check("cycles completed", harness.stats.cycles == harness.cycles)
check("jobs dispatched", harness.stats.dispatched > 0)
check("some jobs completed", total_completed > 0,
  string.format("%d dispatched, %d completed, %d failed",
    harness.stats.dispatched, harness.stats.completed, harness.stats.failed))
check("no invariants broken", harness.stats.invariants_broken == 0)
check("completion rate > 80%",
  harness.stats.completed >= harness.stats.dispatched * 0.8,
  string.format("%.1f%%", harness.stats.dispatched > 0 and
    (harness.stats.completed / harness.stats.dispatched * 100) or 0))

-- Save report
local report_dir = here .. sep .. "reports"
os.execute('mkdir "' .. report_dir .. '" 2>NUL')
harness:save_report(report_dir .. sep .. "soak_thousands.txt")

io.write("\n" .. harness:report() .. "\n")
io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Soak thousands result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
