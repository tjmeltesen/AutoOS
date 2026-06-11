#!/usr/bin/env lua
--[[
  AutoOS — Phase 1 desktop test suite

  Validates the core kernel + maintenance safeguards entirely off-game per
  README §5. Exercises the maintenance parser, the priority-1 shutdown path,
  and the architectural contracts (single poll point, no direct module polling,
  arbitrator-only writes, <=500ms tick budget).

  Run from the project root:
    C:\Lua\lua55.exe tests\phase1_test.lua
]]

--------------------------------------------------------------------------------
-- Make the project modules importable regardless of cwd.
--------------------------------------------------------------------------------

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/phase1_test.lua"
local here = script:match("^(.*)[/\\]") or "."          -- tests dir
package.path = table.concat({
  here .. sep .. "?.lua",                                 -- tests/?.lua
  here .. sep .. ".." .. sep .. "?.lua",                  -- project root
  package.path,
}, ";")

local Mock = require("mock_hardware")
local Maintenance = require("modules.maintenance")
local Kernel = require("main")

--------------------------------------------------------------------------------
-- Tiny assertion harness (style mirrors tests/lua_visual_test.lua).
--------------------------------------------------------------------------------

local ESC = string.char(27)
local function color(code, t) return ESC .. "[" .. code .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function dim(t) return color("2", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0

local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    io.write(green("  PASS  ") .. name)
  else
    failed = failed + 1
    io.write(red("  FAIL  ") .. name)
  end
  if detail then io.write(dim("  -  " .. detail)) end
  io.write("\n")
end

io.write("\n" .. bold("AutoOS Phase 1 — Kernel & Maintenance Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

--------------------------------------------------------------------------------
-- 1. Maintenance parser — formatting strip + fault detection
--------------------------------------------------------------------------------

-- "§" is bytes 0xC2 0xA7 (\194\167); "§c" is a red color code prefix.
local colored = "\194\167cMachine needs a wrench!"
check("strip_format removes the color code",
  Maintenance.strip_format(colored) == "Machine needs a wrench!",
  Maintenance.strip_format(colored))

local FAULT_LINES = {
  "Machine needs a hammer!",
  "Machine needs a wrench!",
  "Machine needs a screwdriver!",
  "Machine needs some duct tape!",
  "Machine needs a hard hammer!",
  "Machine needs a crowbar!",
  "HAS PROBLEMS",
  "Maintenance required",
  "Tool needs repair",
}
for _, line in ipairs(FAULT_LINES) do
  local faulted = Maintenance.has_fault({ line })
  check("detects fault: '" .. line .. "'", faulted == true)
end

check("GT healthy status Problems: 0 is not a fault",
  Maintenance.has_fault({ "Problems: 0 Efficiency: 0.0 %" }) == false)

check("GT Problems: 1 triggers fault",
  Maintenance.has_fault({ "Problems: 1 Efficiency: 90.0 %" }) == true)

local STRUCTURE_LINES = {
  "INCOMPLETE STRUCTURE",
  "Machine structure is incomplete",
  "Invalid structure detected",
  "Structure check failed",
  "Structure not formed correctly",
}
for _, line in ipairs(STRUCTURE_LINES) do
  check("detects structure fault: '" .. line .. "'", Maintenance.has_fault({ line }) == true)
end

check("color-coded fault still detected",
  Maintenance.has_fault({ "\194\167c" .. "Machine needs a wrench!" }) == true)

check("healthy lines produce no fault",
  Maintenance.has_fault({ "Running perfectly.", "Efficiency: 100%" }) == false)

check("empty sensor produces no fault", Maintenance.has_fault({}) == false)
check("nil sensor produces no fault", Maintenance.has_fault(nil) == false)

--------------------------------------------------------------------------------
-- 2. Maintenance.evaluate emits a Priority 1 intent only when faulted
--------------------------------------------------------------------------------

local healthy_intent = Maintenance.evaluate({ sensor = { "Running perfectly." } })
check("no intent when healthy", healthy_intent == nil)

local fault_intent = Maintenance.evaluate({ sensor = { "Machine needs a wrench!" } })
check("intent emitted when faulted", fault_intent ~= nil)
check("intent is priority 1", fault_intent and fault_intent.priority == 1)
check("intent action is force_shutdown",
  fault_intent and fault_intent.action == "force_shutdown")
check("intent carries fault reason",
  fault_intent and fault_intent.reason == "Machine needs a wrench!")

--------------------------------------------------------------------------------
-- 3. Kernel tick — healthy: machine stays on, no shutdown, no beep
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event, verbose = false,
  })
  local result = kernel:tick()
  check("healthy tick commits nothing", result.committed == false)
  check("healthy tick: work still allowed", mock.state.work_allowed == true)
  check("healthy tick: setWorkAllowed never called", mock.stats.setWorkAllowed == 0)
  check("healthy tick: no beep", mock.stats.beep == 0)
end

--------------------------------------------------------------------------------
-- 4. Kernel tick — fault: hard shutdown + audio alarm
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event, verbose = false,
  })
  mock.set_fault("Machine needs a wrench!")
  local result = kernel:tick()
  check("fault tick commits a change", result.committed == true)
  check("fault tick requests shutdown", result.requested_state == false)
  check("fault tick: setWorkAllowed(false) called once", mock.stats.setWorkAllowed == 1)
  check("fault tick: machine work disabled", mock.state.work_allowed == false)
  check("fault tick: machine no longer active", mock.state.active == false)
  check("fault tick: audio alarm fired", mock.stats.beep == 1)
  check("fault tick: winning intent is priority 1",
    result.intent and result.intent.priority == 1)
end

--------------------------------------------------------------------------------
-- 5. Architectural contracts
--------------------------------------------------------------------------------

do
  -- Single poll point: exactly one getSensorInformation per tick.
  local mock = Mock.new()
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event, verbose = false,
  })
  kernel:tick()
  kernel:tick()
  kernel:tick()
  check("single poll point: 1 getSensorInformation per tick",
    mock.stats.getSensorInformation == 3,
    "calls = " .. mock.stats.getSensorInformation)
end

do
  -- Modules must not touch hardware: evaluate() against a plain cache makes
  -- zero calls to the mock machine.
  local mock = Mock.new()
  local before = mock.stats.getSensorInformation + mock.stats.isWorkAllowed
    + mock.stats.setWorkAllowed
  Maintenance.evaluate({ sensor = { "Machine needs a wrench!" } })
  local after = mock.stats.getSensorInformation + mock.stats.isWorkAllowed
    + mock.stats.setWorkAllowed
  check("maintenance module performs zero hardware calls", before == after)
end

--------------------------------------------------------------------------------
-- 6. Tick budget — simulated elapsed within the 500ms target
--------------------------------------------------------------------------------

do
  local mock = Mock.new({ clock_step = 0.02 }) -- 20ms per uptime() call
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event, verbose = false,
  })
  local t0 = mock.computer.uptime()
  kernel:tick()
  local t1 = mock.computer.uptime()
  local elapsed = t1 - t0
  check("tick within 500ms budget", elapsed <= 0.5, string.format("elapsed = %.3fs", elapsed))
end

--------------------------------------------------------------------------------
-- 7. README §5 scenario — scheduled fault flips the machine off at tick 5
--------------------------------------------------------------------------------

do
  local mock = Mock.new({ fault_at_tick = 5 })
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event, verbose = false,
  })
  for _ = 1, 4 do kernel:tick() end
  local pre = mock.state.work_allowed
  local result5 = kernel:tick() -- tick 5: fault appears
  check("README scenario: healthy through tick 4", pre == true)
  check("README scenario: shutdown at tick 5", result5.committed == true
    and mock.state.work_allowed == false)
end

--------------------------------------------------------------------------------
-- 8. Kernel:run respects maxTicks (bounded loop for tests)
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event, verbose = false,
  })
  kernel:run(3)
  check("run(maxTicks) stops after N ticks", kernel.tick_count == 3,
    "ticks = " .. kernel.tick_count)
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

io.write(string.rep("-", 60) .. "\n")
if failed == 0 then
  io.write(bold(green(string.format("  All %d checks passed.\n", passed))))
else
  io.write(bold(red(string.format("  %d failed, %d passed.\n", failed, passed))))
end
io.write("\n")

os.exit(failed == 0 and 0 or 1)
