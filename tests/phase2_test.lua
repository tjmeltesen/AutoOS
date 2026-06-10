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

local function pc_config(kind, mode)
  return { label = LABEL, low = LOW, high = HIGH, kind = kind or "item", mode = mode }
end

local function cache_with_craft(stock, craftable)
  return {
    stock = { [LABEL] = stock },
    craftable = { [LABEL] = craftable },
  }
end

-- Modules return nil, one intent, or an array. Find the intent with `action`.
local function find_intent(out, action)
  if type(out) ~= "table" then return nil end
  if out.action == action then return out end
  for _, intent in ipairs(out) do
    if intent.action == action then return intent end
  end
  return nil
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

  -- At high exactly -> IDLE (boundary must not stay ACTIVE).
  local i3b = pc.evaluate(cache_with(HIGH))
  check("at high turns IDLE", i3b.state == false and pc.active == false)

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
-- 12. ME autocraft — craft mode requests recipes when ACTIVE
--------------------------------------------------------------------------------

do
  local pc = ProcessControl.new(pc_config("fluid", "craft"))
  local out = pc.evaluate(cache_with_craft(LOW - 1000, true))
  check("fluid craft mode emits request_craft",
    find_intent(out, "request_craft") ~= nil)
end

do
  local pc = ProcessControl.new({
    label = LABEL, low = LOW, high = HIGH, kind = "item", mode = "craft",
    max_craft = 10000,
  })
  local out = pc.evaluate(cache_with_craft(LOW - 1000, true))
  local craft_intent = find_intent(out, "request_craft")
  check("max_craft caps request amount", craft_intent and craft_intent.amount == 10000)
end

do
  local pc = ProcessControl.new(pc_config("item", "craft"))
  local out = pc.evaluate(cache_with_craft(LOW - 1000, true))
  local craft_intent = find_intent(out, "request_craft")
  check("craft mode emits request_craft intent", craft_intent ~= nil)
  check("craft amount is deficit to high band",
    craft_intent and craft_intent.amount == HIGH - (LOW - 1000))
  check("craft intent is priority 3", craft_intent and craft_intent.priority == 3)
  check("craft mode also emits machine-on while refilling",
    find_intent(out, "set_work_allowed") ~= nil)
end

do
  local pc = ProcessControl.new(pc_config("item", "craft"))
  local out = pc.evaluate(cache_with_craft(HIGH + 1000, true))
  check("craft mode IDLE above high emits no intents", out == nil)
end

do
  local pc = ProcessControl.new(pc_config("item", "machine"))
  local out = pc.evaluate(cache_with_craft(LOW - 1000, true))
  check("machine mode ignores craftable flag", out.action == "set_work_allowed")
end

do
  local mock = Mock.new()
  mock.set_stock(LABEL, LOW - 1000)
  mock.set_craftable(LABEL, true)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config("item", "craft"), verbose = false,
  })
  local result = kernel:tick()
  check("craft mode commits ME request", result.craft and result.craft.committed == true)
  check("craft request amount matches deficit",
    mock.state.last_craft and mock.state.last_craft.amount == HIGH - (LOW - 1000))
  check("craft mode: no redundant write when machine already ON",
    mock.stats.setWorkAllowed == 0)
end

do
  -- Craft mode must enable a switched-off machine while refilling: the ME
  -- pattern executes on it, so dispatched jobs hang if it stays off.
  local mock = Mock.new()
  mock.set_stock(LABEL, LOW - 1000)
  mock.set_craftable(LABEL, true)
  mock.state.work_allowed = false
  mock.state.active = false
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config("item", "craft"), verbose = false,
  })
  local result = kernel:tick()
  check("craft mode turns machine ON while refilling",
    mock.state.work_allowed == true)
  check("craft mode still requests the craft",
    result.craft and result.craft.committed == true)

  -- Once satisfied, craft mode emits no machine intent (never turns it off).
  mock.set_stock(LABEL, HIGH + 1000)
  local writes = mock.stats.setWorkAllowed
  kernel:tick()
  check("craft mode never turns the machine OFF when satisfied",
    mock.state.work_allowed == true and mock.stats.setWorkAllowed == writes)
end

do
  local mock = Mock.new({ craft_done = false }) -- jobs stay active until finished
  mock.set_stock(LABEL, LOW - 1000)
  mock.set_craftable(LABEL, true)
  mock.state.active = true -- machine busy: phantom ME job should block retry
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config("item", "craft"), verbose = false,
  })
  kernel:tick()
  check("first craft request issued", mock.stats.craft_request == 1)
  local before = mock.stats.craft_request
  kernel:tick()
  check("craft throttled while job active", mock.stats.craft_request == before)
end

do
  local mock = Mock.new({ craft_done = false })
  mock.set_stock(LABEL, LOW - 1000)
  mock.set_craftable(LABEL, true)
  mock.state.active = false -- idle machine (no work)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me,
    process_control = {
      label = LABEL, low = LOW, high = HIGH, kind = "item", mode = "craft",
      max_craft = 16000,
    },
    verbose = false,
  })
  kernel:tick()
  check("idle machine: first batch issued", mock.stats.craft_request == 1)
  mock.state.active = false -- process_control turned work on; keep machine idle
  kernel:tick()
  check("idle machine: no duplicate batch during dispatch grace",
    mock.stats.craft_request == 1)
  mock.advance_clock(16) -- past craft_dispatch_grace (15s)
  kernel:tick()
  check("idle machine: next batch after dispatch grace",
    mock.stats.craft_request == 2)
  check("idle machine: batch size capped",
    mock.state.last_craft and mock.state.last_craft.amount == 16000)
end

do
  local mock = Mock.new({ craft_done = false })
  mock.set_stock(LABEL, LOW - 1000)
  mock.set_craftable(LABEL, true)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config("item", "craft"), verbose = false,
  })
  kernel.arbitrator.craft_job_timeout = 30
  kernel:tick()
  check("stale job blocks first retry", mock.stats.craft_request == 1)
  mock.advance_clock(31)
  kernel:tick()
  check("stale craft job cleared after timeout", mock.stats.craft_request == 2)
end

do
  local mock = Mock.new()
  mock.set_stock(LABEL, LOW - 1000)
  mock.set_craftable(LABEL, true)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config("item", "both"), verbose = false,
  })
  mock.state.work_allowed = false
  mock.state.active = false
  local result = kernel:tick()
  check("both mode drives machine ON", mock.state.work_allowed == true)
  check("both mode also requests craft",
    result.craft and result.craft.committed == true)
end

do
  local mock = Mock.new()
  mock.set_stock(LABEL, LOW - 1000)
  mock.set_craftable(LABEL, true)
  local kernel = Kernel.new({
    machine = mock.machine, computer = mock.computer, event = mock.event,
    me = mock.me, process_control = pc_config("item", "craft"), verbose = false,
  })
  mock.set_fault("Machine needs a wrench!")
  kernel:tick()
  check("maintenance blocks ME craft", mock.stats.craft_request == 0)
end

do
  local mock = Mock.new()
  mock.set_stock(LABEL, LOW - 1000)
  mock.set_craftable(LABEL, true)
  local pc = ProcessControl.new(pc_config("item", "craft"))
  local before = mock.stats.getCraftables + mock.stats.craft_request
  pc.evaluate(cache_with_craft(LOW - 1000, true))
  local after = mock.stats.getCraftables + mock.stats.craft_request
  check("process control performs zero ME craft calls", before == after)
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
