#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/machine_selector_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  package.path,
}, ";")

local MachineSelector = require("rob_services.machine_selector")
local LaneState = require("lane_state")

local ESC = string.char(27)
local function green(t) return ESC .. "[32m" .. t .. ESC .. "[0m" end
local function red(t) return ESC .. "[31m" .. t .. ESC .. "[0m" end
local function bold(t) return ESC .. "[1m" .. t .. ESC .. "[0m" end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write("  -  " .. tostring(detail)) end
  io.write("\n")
end

io.write("\n" .. bold("AutoOS Machine Selector Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- Helpers
local function make_machine(id)
  return { id = id, interface_address = "addr_" .. id }
end

local function make_poll(healthy, available, active, has_work)
  return { healthy = healthy ~= false, available = available ~= false, active = active or false, has_work = has_work or false }
end

local function make_lane(state)
  return { state = state }
end

---------------------------------------------------------------------------
-- available_budget
---------------------------------------------------------------------------
do
  local ms = MachineSelector.new(3)
  check("budget 3 with nil lanes", ms:available_budget(nil) == 3)
  check("budget 3 with empty lanes", ms:available_budget({}) == 3)
  check("budget 3 with 1 working", ms:available_budget({ a = make_lane(LaneState.WORKING) }) == 2)
  check("budget 3 with 3 working", ms:available_budget({
    a = make_lane(LaneState.WORKING), b = make_lane(LaneState.WORKING), c = make_lane(LaneState.WORKING)
  }) == 0)
  check("budget 3 with 4 working clamps to 0", ms:available_budget({
    a = make_lane(LaneState.WORKING), b = make_lane(LaneState.WORKING),
    c = make_lane(LaneState.WORKING), d = make_lane(LaneState.WORKING)
  }) == 0)
  check("idle and faulted don't consume budget", ms:available_budget({
    a = make_lane(LaneState.IDLE), b = make_lane(LaneState.FAULTED)
  }) == 3)
end

do
  local ms = MachineSelector.new(nil)
  check("nil max_lanes returns 999", ms:available_budget({}) == 999)
end

do
  local ms = MachineSelector.new(0)
  check("zero max_lanes returns 999", ms:available_budget({}) == 999)
end

---------------------------------------------------------------------------
-- is_available
---------------------------------------------------------------------------
do
  local m = make_machine("m1")
  local poll_ok = make_poll(true, true)
  local lanes = {}

  check("nil machine -> false", not MachineSelector.is_available(nil, poll_ok, lanes))
  check("machine no id -> false", not MachineSelector.is_available({}, poll_ok, lanes))
  check("nil poll -> false", not MachineSelector.is_available(m, nil, lanes))
  check("poll !healthy -> false", not MachineSelector.is_available(m, make_poll(false, true), lanes))
  check("poll !available -> false", not MachineSelector.is_available(m, make_poll(true, false), lanes))
  check("healthy+available no lane -> true", MachineSelector.is_available(m, poll_ok, lanes))
end

do
  local m = make_machine("m1")
  local lanes = { m1 = make_lane(LaneState.IDLE) }
  check("IDLE lane -> true", MachineSelector.is_available(m, make_poll(true, true), lanes))
end

do
  local m = make_machine("m1")
  local lanes = { m1 = make_lane(LaneState.WORKING) }
  check("WORKING lane -> false", not MachineSelector.is_available(m, make_poll(true, true), lanes))
end

do
  local m = make_machine("m1")
  local lanes = { m1 = make_lane(LaneState.FAULTED) }
  local recovered = {}
  local function recover_fn(id)
    recovered[id] = true
    LaneState.recover(lanes.m1)
  end
  check("FAULTED auto-recovers and returns true",
    MachineSelector.is_available(m, make_poll(true, true), lanes, recover_fn))
  check("recover called", recovered.m1 == true)
  check("lane state is IDLE after recover", LaneState.is_idle(lanes.m1))
end

do
  local m = make_machine("m1")
  local lanes = { m1 = make_lane(LaneState.FAULTED) }
  check("FAULTED without recover_fn -> false",
    not MachineSelector.is_available(m, make_poll(true, true), lanes, nil))
end

---------------------------------------------------------------------------
-- find_available
---------------------------------------------------------------------------
do
  local ms = MachineSelector.new(3)
  local machines = { make_machine("a"), make_machine("b"), make_machine("c") }
  local poll = {
    a = make_poll(true, true),
    b = make_poll(true, true),
    c = make_poll(true, true),
  }
  local m, idx = ms:find_available(machines, poll, {})
  check("first call picks first machine", m.id == "a" and idx == 1)
end

do
  local ms = MachineSelector.new(3)
  local machines = { make_machine("a"), make_machine("b") }
  local poll = {
    a = make_poll(false, false),  -- unhealthy
    b = make_poll(true, true),
  }
  local m, idx = ms:find_available(machines, poll, {})
  check("skips unhealthy machine", m.id == "b" and idx == 2)
end

do
  local ms = MachineSelector.new(3)
  local machines = { make_machine("a"), make_machine("b") }
  local poll = {
    a = make_poll(true, true),
    b = make_poll(true, true),
  }
  local lanes = { a = make_lane(LaneState.WORKING) }
  local m, idx = ms:find_available(machines, poll, lanes)
  check("skips WORKING lane", m.id == "b" and idx == 2)
end

do
  local ms = MachineSelector.new(3)
  local machines = { make_machine("a"), make_machine("b") }
  local poll = {
    a = make_poll(true, true),  -- all OK but WORKING
    b = make_poll(true, true),  -- all OK
  }
  local lanes = {
    a = make_lane(LaneState.WORKING),
    b = make_lane(LaneState.WORKING),
  }
  local m = ms:find_available(machines, poll, lanes)
  check("all busy -> nil", m == nil)
end

do
  local ms = MachineSelector.new(3)
  local machines = { make_machine("a"), make_machine("b"), make_machine("c") }
  local poll = {
    a = make_poll(true, true),
    b = make_poll(true, true),
    c = make_poll(true, true),
  }
  -- First assignment: a
  local m1, i1 = ms:find_available(machines, poll, {})
  ms:advance(i1, machines, true)
  check("first pick is a", m1.id == "a")
  -- Simulate a is now WORKING
  local lanes = { a = make_lane(LaneState.WORKING) }
  local m2, i2 = ms:find_available(machines, poll, lanes)
  check("round-robin wraps to b", m2.id == "b" and i2 == 2)
end

do
  local ms = MachineSelector.new(3)
  local machines = { make_machine("a"), make_machine("b") }
  local poll = {
    a = make_poll(false, true),
    b = make_poll(false, true),
  }
  local diag_log = {}
  local m = ms:find_available(machines, poll, {}, true, nil, function(msg)
    diag_log[#diag_log + 1] = msg
  end)
  check("all unhealthy returns nil", m == nil)
  check("diagnostic includes machine ids", diag_log[1]:find("a:!healthy") and diag_log[1]:find("b:!healthy"))
end

do
  local ms = MachineSelector.new(3)
  local machines = {}
  local m, idx = ms:find_available(machines, {}, {})
  check("empty machines -> nil", m == nil and idx == nil)
end

do
  local ms = MachineSelector.new(3)
  local machines = { make_machine("a") }
  local m, idx = ms:find_available(machines, {}, {}, false)  -- no round-robin
  check("no round-robin uses index 1", m.id == "a" and idx == 1)
end

---------------------------------------------------------------------------
-- advance
---------------------------------------------------------------------------
do
  local ms = MachineSelector.new(3)
  local machines = { make_machine("a"), make_machine("b"), make_machine("c") }
  ms:advance(1, machines, true)
  check("advance from 1 -> 2", ms._rr_index == 2)
  ms:advance(2, machines, true)
  check("advance from 2 -> 3", ms._rr_index == 3)
  ms:advance(3, machines, true)
  check("advance wraps 3 -> 1", ms._rr_index == 1)
end

do
  local ms = MachineSelector.new(3)
  local machines = { make_machine("a") }
  ms:advance(1, machines, false)
  check("no round-robin leaves index unchanged", ms._rr_index == 1)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Machine selector result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
