#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/admission_control_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local AdmissionControl = require("rob_services.admission_control")

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

io.write("\n" .. bold("AutoOS Admission Control Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local C = { LANE_IDLE = 1, LANE_WORKING = 2, LANE_FAULTED = 3 }

---------------------------------------------------------------------------
-- max_circuits
---------------------------------------------------------------------------
do
  check("central.max_circuits_in_buffer wins", AdmissionControl.max_circuits({
    central = { max_circuits_in_buffer = 5 },
    max_circuits_in_buffer = 10,
  }) == 5)

  check("falls back to top-level max_circuits_in_buffer", AdmissionControl.max_circuits({
    max_circuits_in_buffer = 8,
  }) == 8)

  check("returns nil when neither is set", AdmissionControl.max_circuits({}) == nil)
end

---------------------------------------------------------------------------
-- job_stabilize_s
---------------------------------------------------------------------------
do
  check("central.job_stabilize_s", AdmissionControl.job_stabilize_s({
    central = { job_stabilize_s = 5.0 },
  }) == 5.0)

  check("central.stabilize_s fallback", AdmissionControl.job_stabilize_s({
    central = { stabilize_s = 2.5 },
  }) == 2.5)

  check("default is 3.0", AdmissionControl.job_stabilize_s({}) == 3.0)
end

---------------------------------------------------------------------------
-- is_ok (with stubbed count_circuits)
---------------------------------------------------------------------------
local _orig_count = AdmissionControl.count_circuits

do
  local logs = {}
  local function log_fn(msg) logs[#logs + 1] = msg end

  -- Stub count_circuits to return 0
  AdmissionControl.count_circuits = function() return 0 end

  check("0 circuits always ok", AdmissionControl.is_ok({}, { max_circuits_in_buffer = 3 }, nil, {}, log_fn, nil, C))
  check("no log when ok", #logs == 0)

  -- Restore
  AdmissionControl.count_circuits = _orig_count
end

do
  local logs = {}
  local function log_fn(msg) logs[#logs + 1] = msg end

  AdmissionControl.count_circuits = function() return 5 end

  check("5 circuits > max 3 -> blocked", not AdmissionControl.is_ok({}, { max_circuits_in_buffer = 3 }, nil, {}, log_fn, nil, C))
  check("log includes effective count", logs[1]:find("effective 5") ~= nil)

  AdmissionControl.count_circuits = _orig_count
end

do
  -- 5 circuits, 3 working lanes → effective 2, under max 3 → OK
  local logs = {}
  local function log_fn(msg) logs[#logs + 1] = msg end

  AdmissionControl.count_circuits = function() return 5 end

  local lanes = {
    a = { state = C.LANE_WORKING },
    b = { state = C.LANE_WORKING },
    c = { state = C.LANE_WORKING },
  }
  check("5 circuits - 3 inflight = 2 effective < max 3 -> ok",
    AdmissionControl.is_ok({}, { max_circuits_in_buffer = 3 }, nil, lanes, log_fn, nil, C))
  check("no log when inflight deduction makes it ok", #logs == 0)

  AdmissionControl.count_circuits = _orig_count
end

do
  -- No max_circuits configured → always OK
  AdmissionControl.count_circuits = function() return 100 end
  check("no max -> always ok", AdmissionControl.is_ok({}, {}, nil, {}, function() end, nil, C))
  AdmissionControl.count_circuits = _orig_count
end

do
  -- max_circuits = 0 → always OK (disabled)
  AdmissionControl.count_circuits = function() return 100 end
  check("max_circuits=0 disables check", AdmissionControl.is_ok({}, { max_circuits_in_buffer = 0 }, nil, {}, function() end, nil, C))
  AdmissionControl.count_circuits = _orig_count
end

do
  -- nil lanes table handled gracefully
  local logs = {}
  AdmissionControl.count_circuits = function() return 5 end
  check("nil lanes with excess circuits -> blocked",
    not AdmissionControl.is_ok({}, { max_circuits_in_buffer = 3 }, nil, nil, function(msg) logs[#logs+1]=msg end, nil, C))
  AdmissionControl.count_circuits = _orig_count
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Admission control result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
