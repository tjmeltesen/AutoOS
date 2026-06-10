#!/usr/bin/env lua
--[[
  AutoOS — Read-Only Display test suite

  Verifies the thin status panel renders the State Cache snapshot to a (mock)
  GPU and, critically, that it is READ-ONLY: rendering performs zero gt_machine
  or ME-network calls, and wiring a display into the kernel does not change the
  control/commit behavior or the single-poll contract.

  Run from the project root:
    C:\Lua\lua55.exe tests\display_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/display_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  package.path,
}, ";")

local Mock = require("mock_hardware")
local Display = require("display")
local Kernel = require("main")

local ESC = string.char(27)
local function color(code, t) return ESC .. "[" .. code .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function dim(t) return color("2", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write(dim("  -  " .. detail)) end
  io.write("\n")
end

-- Search the mock GPU's rendered rows for a substring.
local function rows_contain(mock, substr)
  for _, line in pairs(mock.state.gpu_rows) do
    if type(line) == "string" and line:find(substr, 1, true) then
      return true
    end
  end
  return false
end

io.write("\n" .. bold("AutoOS — Read-Only Status Display Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local LABEL = "Soldering Alloy"
local LOW, HIGH = 64000, 142800
local function pc_config() return { label = LABEL, low = LOW, high = HIGH, kind = "item" } end

--------------------------------------------------------------------------------
-- 1. Construction binds the screen and applies a resolution.
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local disp = Display.new(mock.gpu, "screen-addr-1")
  check("constructs against a gpu proxy", disp ~= nil)
  check("binds the provided screen", mock.state.gpu_bound == "screen-addr-1")
  check("applies a clamped resolution", disp.width == 60 and disp.height == 16,
    string.format("%sx%s", tostring(disp.width), tostring(disp.height)))
  check("clears the screen on init", mock.stats.gpu_fill >= 1)
end

--------------------------------------------------------------------------------
-- 2. render() writes the expected content to the GPU.
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local disp = Display.new(mock.gpu)
  disp:render({
    tick = 7,
    work_allowed = true, active = true, has_work = true, eu_input = 0,
    pc = { label = LABEL, stock = 63000, active = true, low = LOW, high = HIGH },
    action = "set_work_allowed", committed = true, requested_state = true,
  })
  check("render writes rows to the gpu", mock.stats.gpu_set > 0,
    "set calls = " .. mock.stats.gpu_set)
  check("renders the monitor title + tick", rows_contain(mock, "AutoOS Monitor")
    and rows_contain(mock, "tick 7"))
  check("renders machine state", rows_contain(mock, "work=ON"))
  check("renders the tracked product + band", rows_contain(mock, LABEL)
    and rows_contain(mock, "63000"))
  check("renders ACTIVE process-control state", rows_contain(mock, "ACTIVE"))
  check("renders the arbitrator action", rows_contain(mock, "set_work_allowed"))
end

--------------------------------------------------------------------------------
-- 3. Fault snapshot shows the maintenance banner.
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local disp = Display.new(mock.gpu)
  disp:render({
    tick = 9, work_allowed = false, active = false,
    action = "force_shutdown", committed = true, requested_state = false,
    fault = "Machine needs a wrench!",
  })
  check("renders a maintenance fault banner", rows_contain(mock, "MAINTENANCE FAULT"))
  check("renders the fault reason", rows_contain(mock, "needs a wrench"))
end

--------------------------------------------------------------------------------
-- 4. Display is READ-ONLY: render performs zero machine/ME calls.
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local disp = Display.new(mock.gpu)
  local before = mock.stats.getSensorInformation + mock.stats.isWorkAllowed
    + mock.stats.setWorkAllowed + mock.stats.getItemsInNetwork
    + mock.stats.getFluidsInNetwork
  disp:render({
    tick = 1, work_allowed = true, active = true,
    pc = { label = LABEL, stock = 100000, active = false, low = LOW, high = HIGH },
    committed = false,
  })
  local after = mock.stats.getSensorInformation + mock.stats.isWorkAllowed
    + mock.stats.setWorkAllowed + mock.stats.getItemsInNetwork
    + mock.stats.getFluidsInNetwork
  check("display makes zero machine/ME calls", before == after)
end

--------------------------------------------------------------------------------
-- 5. Phase 1-only snapshot (no process control) renders without error.
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local disp = Display.new(mock.gpu)
  local ok = pcall(function()
    disp:render({ tick = 2, work_allowed = true, active = false, committed = false })
  end)
  check("renders cleanly without a process-control section", ok == true)
  check("still shows machine + maintenance rows", rows_contain(mock, "Machine")
    and rows_contain(mock, "Maintenance OK"))
end

--------------------------------------------------------------------------------
-- 6. Kernel + display: control behavior and single-poll contract unaffected.
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  mock.state.work_allowed = false -- idle machine
  mock.state.active = false
  mock.set_stock(LABEL, LOW - 1000)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config(),
    gpu = mock.gpu, screen = "screen-addr-2", verbose = false,
  })
  check("kernel builds the display", kernel.display ~= nil)
  local result = kernel:tick()
  check("control still drives machine ON with display attached",
    result.committed == true and mock.state.work_allowed == true)
  check("display rendered during the tick", mock.stats.gpu_set > 0)

  kernel:tick(); kernel:tick()
  check("single-poll contract intact with display (3 polls / 3 ticks)",
    mock.stats.getSensorInformation == 3,
    "polls = " .. mock.stats.getSensorInformation)
end

--------------------------------------------------------------------------------
-- 6b. Steady-state maintenance fault stays visible on the panel.
-- Change-only writes mean ticks after the shutdown commit nothing; the fault
-- banner must still show (regression: panel said "Maintenance OK" while a
-- standing fault silently suppressed all crafting).
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  mock.set_stock(LABEL, LOW - 1000)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config(),
    gpu = mock.gpu, screen = "screen-addr-3", verbose = false,
  })
  mock.set_fault("Machine needs a wrench!")
  kernel:tick() -- commits the shutdown, renders fault banner
  kernel:tick() -- nothing commits, but the fault is still standing
  check("fault banner persists after the shutdown tick",
    rows_contain(mock, "MAINTENANCE FAULT"))
end

--------------------------------------------------------------------------------
-- 7. No gpu => no display, fully headless (Phase 1/2 behavior unchanged).
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    verbose = false, -- no gpu
  })
  check("display disabled without a gpu proxy", kernel.display == nil)
  kernel:tick()
  check("no gpu writes when headless", mock.stats.gpu_set == 0)
end

io.write(string.rep("-", 60) .. "\n")
if failed == 0 then
  io.write(bold(green(string.format("  All %d checks passed.\n", passed))))
else
  io.write(bold(red(string.format("  %d failed, %d passed.\n", failed, passed))))
end
io.write("\n")

os.exit(failed == 0 and 0 or 1)
