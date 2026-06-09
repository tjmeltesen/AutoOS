#!/usr/bin/env lua
--[[
  AutoOS — Phase 2 desktop test suite

  Validates the Multiblock Process Control & Leveling Engine (Module 1) off-game
  per README §5: the dual-threshold hysteresis loop, the Priority 1 > Priority 3
  override, arbitrator change-only writes, and the architectural contracts
  (adapter is the single ME poll point, modules never touch hardware).

  Run from the project root:
    C:\Lua\lua55.exe tests\phase2_test.lua
]]

--------------------------------------------------------------------------------
-- Make the project modules importable regardless of cwd.
--------------------------------------------------------------------------------

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/phase2_test.lua"
local here = script:match("^(.*)[/\\]") or "."          -- tests dir
package.path = table.concat({
  here .. sep .. "?.lua",                                 -- tests/?.lua
  here .. sep .. ".." .. sep .. "?.lua",                  -- project root
  package.path,
}, ";")

local Mock = require("mock_hardware")
local ProcessControl = require("modules.process_control")
local Kernel = require("main")

--------------------------------------------------------------------------------
-- Tiny assertion harness (style mirrors tests/phase1_test.lua).
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

io.write("\n" .. bold("AutoOS Phase 2 — Process Control & Hysteresis Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local LABEL = "Soldering Alloy"
local LOW, HIGH = 64000, 142800

local function cache_with(stock)
  return { stock = { [LABEL] = stock } }
end

local function pc_config(kind)
  return { label = LABEL, low = LOW, high = HIGH, kind = kind or "item" }
end

--------------------------------------------------------------------------------
-- 1. ProcessControl construction guards
--------------------------------------------------------------------------------

do
  local ok = pcall(ProcessControl.new, { label = LABEL, low = 10, high = 20 })
  check("constructs with valid config", ok == true)

  local bad_band = pcall(ProcessControl.new, { label = LABEL, low = 100, high = 50 })
  check("rejects high <= low (no deadband)", bad_band == false)

  local no_label = pcall(ProcessControl.new, { low = 10, high = 20 })
  check("rejects missing label", no_label == false)
end

--------------------------------------------------------------------------------
-- 2. Hysteresis state machine — bands and deadband hold
--------------------------------------------------------------------------------

do
  local pc = ProcessControl.new(pc_config())

  -- Below low -> ACTIVE.
  local i1 = pc.evaluate(cache_with(LOW - 1))
  check("below low turns ACTIVE", i1.state == true and pc.active == true)
  check("intent is priority 3", i1.priority == 3)
  check("intent action is set_work_allowed", i1.action == "set_work_allowed")
  check("intent module is process_control", i1.module == "process_control")
  check("intent carries stock reading", i1.stock == LOW - 1)

  -- Inside deadband while ACTIVE -> hold ACTIVE (no premature shutoff).
  local i2 = pc.evaluate(cache_with((LOW + HIGH) // 2))
  check("deadband holds ACTIVE while filling", i2.state == true)

  -- Above high -> IDLE.
  local i3 = pc.evaluate(cache_with(HIGH + 1))
  check("above high turns IDLE", i3.state == false and pc.active == false)

  -- Inside deadband while IDLE -> hold IDLE (no premature restart = no flapping).
  local i4 = pc.evaluate(cache_with((LOW + HIGH) // 2))
  check("deadband holds IDLE after fill", i4.state == false)

  -- Back below low -> ACTIVE again.
  local i5 = pc.evaluate(cache_with(LOW - 1))
  check("re-arms ACTIVE below low", i5.state == true)
end

--------------------------------------------------------------------------------
-- 3. No flapping across a depletion/refill sweep
--------------------------------------------------------------------------------

do
  local pc = ProcessControl.new(pc_config())
  local transitions, prev = 0, pc.active
  -- Deplete from HIGH+ down to below LOW, then refill back up past HIGH.
  local levels = {}
  for v = HIGH + 5000, LOW - 5000, -5000 do levels[#levels + 1] = v end
  for v = LOW - 5000, HIGH + 5000, 5000 do levels[#levels + 1] = v end
  for _, v in ipairs(levels) do
    local intent = pc.evaluate(cache_with(v))
    if intent.state ~= prev then
      transitions = transitions + 1
      prev = intent.state
    end
  end
  -- A clean hysteresis loop flips at most twice (off->on once, on->off once).
  check("at most 2 state transitions over a full sweep", transitions <= 2,
    "transitions = " .. transitions)
end

--------------------------------------------------------------------------------
-- 4. Unknown stock holds the last state (no ME proxy / not yet polled)
--------------------------------------------------------------------------------

do
  local pc = ProcessControl.new(pc_config())
  pc.evaluate(cache_with(LOW - 1)) -- becomes ACTIVE
  local held = pc.evaluate({}) -- no stock table
  check("holds ACTIVE when stock unknown", held.state == true)
  check("unknown stock intent has nil stock", held.stock == nil)
end

--------------------------------------------------------------------------------
-- 5. Kernel — low stock drives an idle machine ON
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  mock.state.work_allowed = false -- machine manually idle
  mock.state.active = false
  mock.set_stock(LABEL, LOW - 1000)

  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config(), verbose = false,
  })
  local result = kernel:tick()
  check("low stock commits work_allowed change", result.committed == true)
  check("requested state is ON", result.requested_state == true)
  check("machine driven ACTIVE", mock.state.work_allowed == true)
  check("winning intent is process_control",
    result.intent and result.intent.module == "process_control")
end

--------------------------------------------------------------------------------
-- 6. Kernel — high stock stops a running machine
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  mock.set_stock(LABEL, HIGH + 1000) -- already full
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config(), verbose = false,
  })
  -- Machine starts work_allowed=true (default). Stock above high -> turn OFF.
  local result = kernel:tick()
  check("high stock requests OFF", result.requested_state == false)
  check("setWorkAllowed(false) committed", result.committed == true
    and mock.state.work_allowed == false)
end

--------------------------------------------------------------------------------
-- 7. Arbitrator change-only writes — no redundant setWorkAllowed
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  -- Machine already running (default work_allowed=true); stock below low so
  -- process control also wants it ON. No hardware change should be written.
  mock.set_stock(LABEL, LOW - 1000)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config(), verbose = false,
  })
  local r1 = kernel:tick()
  check("no write when already in requested ON state", r1.committed == false
    and mock.stats.setWorkAllowed == 0)

  -- Now satisfy stock -> request OFF (one write).
  mock.set_stock(LABEL, HIGH + 1000)
  kernel:tick()
  check("one write on ON->OFF transition", mock.stats.setWorkAllowed == 1)

  -- Hold OFF (stock still high) -> no further write.
  kernel:tick()
  check("no redundant write while holding OFF", mock.stats.setWorkAllowed == 1)
end

--------------------------------------------------------------------------------
-- 8. Priority override — maintenance (P1) beats process control (P3)
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  mock.set_stock(LABEL, LOW - 1000) -- process control wants ON
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config(), verbose = false,
  })
  mock.set_fault("Machine needs a wrench!") -- inject P1 maintenance fault
  local result = kernel:tick()
  check("priority 1 maintenance wins over priority 3",
    result.intent and result.intent.priority == 1)
  check("force_shutdown action committed", result.action == "force_shutdown")
  check("machine forced OFF despite low stock", mock.state.work_allowed == false)
  check("audio alarm fired", mock.stats.beep == 1)
end

--------------------------------------------------------------------------------
-- 9. Fluid target — getFluidsInNetwork path drives hysteresis
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  mock.state.work_allowed = false
  mock.state.active = false
  mock.set_fluid(LABEL, LOW - 1000)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config("fluid"), verbose = false,
  })
  local result = kernel:tick()
  check("fluid below low drives machine ON", result.requested_state == true
    and mock.state.work_allowed == true)
  check("fluid path used getFluidsInNetwork", mock.stats.getFluidsInNetwork >= 1)
end

--------------------------------------------------------------------------------
-- 10. Contracts — single ME poll point + module makes zero hardware calls
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  mock.set_stock(LABEL, LOW - 1000)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config(), verbose = false,
  })
  kernel:tick(); kernel:tick(); kernel:tick()
  check("single ME poll point: 1 getItemsInNetwork per tick (item target)",
    mock.stats.getItemsInNetwork == 3,
    "calls = " .. mock.stats.getItemsInNetwork)
end

do
  local mock = Mock.new()
  mock.set_stock(LABEL, LOW - 1000)
  local pc = ProcessControl.new(pc_config())
  local before = mock.stats.getItemsInNetwork + mock.stats.getFluidsInNetwork
    + mock.stats.setWorkAllowed
  pc.evaluate(cache_with(LOW - 1)) -- pure cache read
  local after = mock.stats.getItemsInNetwork + mock.stats.getFluidsInNetwork
    + mock.stats.setWorkAllowed
  check("process control performs zero hardware/ME calls", before == after)
end

--------------------------------------------------------------------------------
-- 11. Phase 1 unaffected — no ME proxy means Phase 1-only behavior
--------------------------------------------------------------------------------

do
  local mock = Mock.new()
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    verbose = false, -- no me / process_control
  })
  check("process_control disabled without ME proxy", kernel.process_control == nil)
  local result = kernel:tick()
  check("healthy Phase 1-only tick writes nothing", result.committed == false
    and mock.stats.setWorkAllowed == 0)
  check("no ME polling without a proxy", mock.stats.getItemsInNetwork == 0)
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
