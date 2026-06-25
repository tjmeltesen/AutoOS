#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/lane_state_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  package.path,
}, ";")

local LaneState = require("lane_state")

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

io.write("\n" .. bold("LaneState FSM Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local lane = LaneState.create("machine_01", function() return 100 end)
  check("create returns IDLE lane", LaneState.is_idle(lane))
  check("create sets state_entered_at", lane.state_entered_at == 100, tostring(lane.state_entered_at))
  check("create has nil job_id", lane.current_job_id == nil)
  check("create has empty locked_resources", type(lane.locked_resources) == "table" and #lane.locked_resources == 0)
  check("create has zero deadline", lane.deadline == 0)
end

do
  local lane = LaneState.create("machine_01")
  local now = 200
  LaneState.assign(lane, "job_001", { "interface:uuid-ae", "tp:uuid-tp" }, 300, function() return now end)
  check("assign transitions to WORKING", LaneState.is_working(lane))
  check("assign records job_id", lane.current_job_id == "job_001")
  check("assign records locked_resources", #lane.locked_resources == 2)
  check("assign records deadline", lane.deadline == 300)
  check("assign clears last_error", lane.last_error == nil)
  check("assign records state_entered_at", lane.state_entered_at == now)
end

do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001")
  LaneState.complete(lane)
  check("complete transitions to IDLE", LaneState.is_idle(lane))
  check("complete clears job_id", lane.current_job_id == nil)
  check("complete clears last_error", lane.last_error == nil)
end

do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001")
  LaneState.fault(lane, "timeout after 60s")
  check("fault transitions to FAULTED", LaneState.is_faulted(lane))
  check("fault clears job_id", lane.current_job_id == nil)
  check("fault records error", lane.last_error == "timeout after 60s")
end

do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001")
  LaneState.fault(lane, "test fault")
  local recovered = LaneState.recover(lane)
  check("recover returns true on FAULTED lane", recovered == true)
  check("recover transitions to IDLE", LaneState.is_idle(lane))
end

do
  local lane = LaneState.create("machine_01")
  local recovered = LaneState.recover(lane)
  check("recover on IDLE lane returns false", recovered == false)
  check("recover on IDLE lane stays IDLE", LaneState.is_idle(lane))
end

do
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001", { "res1" }, 500)
  local released
  LaneState.reset(lane, "manual reset", function(l) released = l.locked_resources end)
  check("reset transitions to IDLE", LaneState.is_idle(lane))
  check("reset calls release_fn", released ~= nil)
  check("reset clears locked_resources", #lane.locked_resources == 0)
  check("reset records reason", lane.last_error == "manual reset")
end

do
  local lane = LaneState.create("machine_01")
  check("is_idle true for IDLE", LaneState.is_idle(lane))
  check("is_working false for IDLE", not LaneState.is_working(lane))
  check("is_faulted false for IDLE", not LaneState.is_faulted(lane))

  LaneState.assign(lane, "job_002")
  check("is_idle false for WORKING", not LaneState.is_idle(lane))
  check("is_working true for WORKING", LaneState.is_working(lane))

  LaneState.fault(lane, "error")
  check("is_faulted true for FAULTED", LaneState.is_faulted(lane))
end

do
  -- Nil guard
  check("is_idle nil guard", not LaneState.is_idle(nil))
  check("is_working nil guard", not LaneState.is_working(nil))
  check("is_faulted nil guard", not LaneState.is_faulted(nil))
end

do
  -- Reassignment (WORKING -> WORKING with new job)
  local lane = LaneState.create("machine_01")
  LaneState.assign(lane, "job_001", { "res1" }, 500)
  LaneState.assign(lane, "job_002", { "res2" }, 600)
  check("reassign updates job_id", lane.current_job_id == "job_002")
  check("reassign updates resources", lane.locked_resources[1] == "res2")
  check("reassign updates deadline", lane.deadline == 600)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("LaneState result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
