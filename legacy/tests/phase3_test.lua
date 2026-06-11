#!/usr/bin/env lua
--[[
  AutoOS — Phase 3 desktop test suite

  Validates the Raw Resource Management & Projection module (Module 3) off-game
  per references/phase3-implementation.md: ring-buffer history, consumption
  velocity / time-to-depletion math, Priority 2 soft sleep, the P1 > P2 > P3
  arbitration order, edge-triggered depletion alerts, and the architectural
  contracts (adapter is the single ME poll point, modules never touch hardware).

  Run from the project root:
    C:\Lua\lua55.exe tests\phase3_test.lua
]]

--------------------------------------------------------------------------------
-- Make the project modules importable regardless of cwd.
--------------------------------------------------------------------------------

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/phase3_test.lua"
local here = script:match("^(.*)[/\\]") or "."          -- tests dir
package.path = table.concat({
  here .. sep .. "?.lua",                                 -- tests/?.lua
  here .. sep .. ".." .. sep .. "?.lua",                  -- project root
  package.path,
}, ";")

local Mock = require("mock_hardware")
local ResourceManager = require("modules.resource_manager")
local Kernel = require("main")

--------------------------------------------------------------------------------
-- Tiny assertion harness (style mirrors tests/phase2_test.lua).
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

io.write("\n" .. bold("AutoOS Phase 3 — Resource Management & Projection Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local OUTPUT = "Oxygen"
local INPUT = "Empty Cell"

local function rm_config(overrides)
  local cfg = {
    inputs = {
      { label = INPUT, kind = "item", min = 1000, warn_ttd = 1800 },
    },
  }
  for k, v in pairs(overrides or {}) do cfg[k] = v end
  return cfg
end

--------------------------------------------------------------------------------
-- 1. Pure math: ring buffer, velocity, TTD
--------------------------------------------------------------------------------

io.write(dim("\n-- pure ring / velocity / TTD math --\n"))

do
  local ring = {}
  for i = 1, 61 do
    ResourceManager.append_sample(ring, i, 1000 - i, 60)
  end
  check("ring buffer capped at 60 samples", #ring == 60,
    "len=" .. #ring)
  check("ring drops oldest sample first", ring[1].t == 2 and ring[60].t == 61,
    string.format("first.t=%s last.t=%s", tostring(ring[1].t), tostring(ring[60].t)))
end

do
  check("velocity nil with fewer than 2 samples",
    ResourceManager.compute_velocity({ { t = 0, count = 5 } }) == nil)
  check("velocity nil when window under 1s",
    ResourceManager.compute_velocity({
      { t = 0, count = 100 }, { t = 0.5, count = 90 },
    }) == nil)

  local draining = { { t = 0, count = 10000 }, { t = 10, count = 9000 } }
  local v = ResourceManager.compute_velocity(draining)
  check("velocity -100/s over 10s drain of 1000", v == -100,
    "v=" .. tostring(v))

  local rising = { { t = 0, count = 100 }, { t = 10, count = 200 } }
  check("velocity positive when stock rising",
    ResourceManager.compute_velocity(rising) == 10)
end

do
  check("ttd nil without velocity", ResourceManager.compute_ttd(500, nil) == nil)
  check("ttd infinite when stock stable",
    ResourceManager.compute_ttd(500, 0) == math.huge)
  check("ttd infinite when stock rising",
    ResourceManager.compute_ttd(500, 25) == math.huge)
  local ttd = ResourceManager.compute_ttd(9000, -100)
  check("ttd = stock / |velocity| when draining", ttd == 90,
    "ttd=" .. tostring(ttd))
end

--------------------------------------------------------------------------------
-- 2. Construction guards
--------------------------------------------------------------------------------

io.write(dim("\n-- construction guards --\n"))

do
  local ok = pcall(ResourceManager.new, nil)
  check("new(nil) rejected", not ok)
  ok = pcall(ResourceManager.new, { inputs = {} })
  check("empty inputs rejected", not ok)
  ok = pcall(ResourceManager.new, { inputs = { { label = INPUT } } })
  check("input without numeric min rejected", not ok)
  ok = pcall(ResourceManager.new, rm_config())
  check("valid config accepted", ok)
end

--------------------------------------------------------------------------------
-- 3. evaluate(): soft sleep intent
--------------------------------------------------------------------------------

io.write(dim("\n-- soft sleep evaluation --\n"))

do
  local rm = ResourceManager.new(rm_config())

  local out = rm.evaluate({ stock = { [INPUT] = 5000 } })
  check("healthy input -> no intent", out == nil)

  out = rm.evaluate({ stock = { [INPUT] = 200 } })
  check("input below min -> intent emitted", type(out) == "table")
  check("soft sleep intent is Priority 2", out and out.priority == 2,
    "priority=" .. tostring(out and out.priority))
  check("soft sleep intent action/state", out
    and out.action == "soft_sleep" and out.state == false)
  check("soft sleep intent carries module/label", out
    and out.module == "resource_manager" and out.label == INPUT)

  out = rm.evaluate({ stock = {} })
  check("missing stock reading -> soft sleep", out
    and out.action == "soft_sleep")

  out = rm.evaluate({ stock = { [INPUT] = 200 }, power_loss = true })
  check("power loss -> no redundant OFF intent", out == nil)
end

do
  local rm = ResourceManager.new(rm_config({ soft_sleep = false }))
  local out = rm.evaluate({ stock = { [INPUT] = 200 } })
  check("soft_sleep=false -> alert-only module emits nothing", out == nil)
end

--------------------------------------------------------------------------------
-- 4. TTD alert edge-triggering
--------------------------------------------------------------------------------

io.write(dim("\n-- depletion alert edge --\n"))

do
  local rm = ResourceManager.new(rm_config())
  local cache = {
    stock = { [INPUT] = 5000 },
    velocity = { [INPUT] = -2 },
    ttd = { [INPUT] = 1700 },
  }

  rm.evaluate(cache)
  check("alert fires when TTD crosses below warn_ttd",
    rm.last_alert ~= nil and rm.last_alert.label == INPUT)

  rm.evaluate(cache)
  check("alert does not repeat while condition persists", rm.last_alert == nil)

  cache.ttd[INPUT] = 4000
  rm.evaluate(cache)
  check("alert resets once TTD recovers", rm.last_alert == nil)

  cache.ttd[INPUT] = 1500
  rm.evaluate(cache)
  check("alert re-fires on the next crossing", rm.last_alert ~= nil)
end

do
  local rm = ResourceManager.new(rm_config())
  rm.evaluate({
    stock = { [INPUT] = 5000 },
    velocity = { [INPUT] = 3 },
    ttd = { [INPUT] = math.huge },
  })
  check("no alert while stock stable/rising", rm.last_alert == nil)
end

--------------------------------------------------------------------------------
-- 5. Adapter history: ring buffers, velocity, TTD in cache
--------------------------------------------------------------------------------

io.write(dim("\n-- adapter history & projections --\n"))

do
  local hw = Mock.new({ stock = { [INPUT] = 10000 }, craftables = {} })
  local kernel = Kernel.new({
    machine = hw.machine, computer = hw.computer, event = hw.event, me = hw.me,
    resource_manager = rm_config(),
  })

  -- Drain 100 items every 5 seconds across 5 ticks.
  for _ = 1, 5 do
    kernel:tick()
    hw.advance_clock(5)
    hw.drain_stock(INPUT, 100)
  end

  local ring = kernel.cache.history and kernel.cache.history[INPUT]
  check("cache.history ring populated by adapter", type(ring) == "table" and #ring == 5,
    "samples=" .. tostring(ring and #ring))

  local v = kernel.cache.velocity and kernel.cache.velocity[INPUT]
  check("cache.velocity negative while draining", type(v) == "number" and v < 0,
    "v=" .. tostring(v))

  local ttd = kernel.cache.ttd and kernel.cache.ttd[INPUT]
  check("cache.ttd finite while draining",
    type(ttd) == "number" and ttd > 0 and ttd < math.huge,
    "ttd=" .. tostring(ttd))
end

do
  -- Stable stock: velocity 0, TTD infinite — never NaN.
  local hw = Mock.new({ stock = { [INPUT] = 10000 }, craftables = {} })
  local kernel = Kernel.new({
    machine = hw.machine, computer = hw.computer, event = hw.event, me = hw.me,
    resource_manager = rm_config(),
  })
  for _ = 1, 3 do
    kernel:tick()
    hw.advance_clock(5)
  end
  local v = kernel.cache.velocity[INPUT]
  local ttd = kernel.cache.ttd[INPUT]
  check("stable stock -> velocity 0, TTD infinite",
    v == 0 and ttd == math.huge,
    string.format("v=%s ttd=%s", tostring(v), tostring(ttd)))
end

--------------------------------------------------------------------------------
-- 6. Priority arbitration: P2 over P3, P1 over P2
--------------------------------------------------------------------------------

io.write(dim("\n-- priority arbitration --\n"))

local function pc_rm_kernel(opts)
  opts = opts or {}
  local hw = Mock.new({
    stock = {
      [OUTPUT] = opts.output_stock or 100,    -- below low: P3 wants ON + craft
      [INPUT] = opts.input_stock or 100,      -- below min: P2 wants OFF
    },
    craftables = { [OUTPUT] = true },
    fault_at_tick = opts.fault_at_tick,
  })
  local kernel = Kernel.new({
    machine = hw.machine, computer = hw.computer, event = hw.event, me = hw.me,
    process_control = {
      label = OUTPUT, low = 64000, high = 142800, kind = "item", mode = "both",
    },
    resource_manager = rm_config(),
  })
  return hw, kernel
end

do
  local hw, kernel = pc_rm_kernel({ input_stock = 100 })
  local result = kernel:tick()
  check("P2 soft sleep beats P3 refill",
    result.intent and result.intent.module == "resource_manager",
    "winner=" .. tostring(result.intent and result.intent.module))
  check("soft sleep turns the machine OFF",
    hw.state.work_allowed == false)
  check("soft sleep suppresses ME craft requests",
    hw.stats.craft_request == 0)
  check("soft sleep does not beep", hw.stats.beep == 0)
end

do
  local hw, kernel = pc_rm_kernel({ input_stock = 100, fault_at_tick = 1 })
  local result = kernel:tick()
  check("P1 maintenance beats P2 soft sleep",
    result.intent and result.intent.module == "maintenance",
    "winner=" .. tostring(result.intent and result.intent.module))
  check("maintenance shutdown still beeps", hw.stats.beep == 1)
end

do
  -- Recovery: restore the input above min -> P3 resumes refilling next tick.
  local hw, kernel = pc_rm_kernel({ input_stock = 100 })
  kernel:tick()
  check("machine OFF while input missing", hw.state.work_allowed == false)

  hw.set_stock(INPUT, 5000)
  hw.advance_clock(20) -- past arbitrator craft cooldown
  local result = kernel:tick()
  check("input restored -> P3 wins again",
    result.intent and result.intent.module == "process_control",
    "winner=" .. tostring(result.intent and result.intent.module))
  check("machine re-enabled after recovery", hw.state.work_allowed == true)
  check("ME craft resumes after recovery", hw.stats.craft_request == 1,
    "requests=" .. tostring(hw.stats.craft_request))
end

--------------------------------------------------------------------------------
-- 7. Architectural contracts
--------------------------------------------------------------------------------

io.write(dim("\n-- architecture contracts --\n"))

do
  -- Module makes zero hardware/ME calls: counters frozen across evaluate.
  local hw = Mock.new({ stock = { [INPUT] = 100 } })
  local rm = ResourceManager.new(rm_config())
  local before_me = hw.stats.me_calls
  local before_sensor = hw.stats.getSensorInformation
  local before_set = hw.stats.setWorkAllowed
  rm.evaluate({ stock = { [INPUT] = 100 } })
  rm.evaluate({ stock = { [INPUT] = 5000 }, ttd = { [INPUT] = 900 },
    velocity = { [INPUT] = -1 } })
  check("module makes zero hardware/ME calls",
    hw.stats.me_calls == before_me
    and hw.stats.getSensorInformation == before_sensor
    and hw.stats.setWorkAllowed == before_set)
end

do
  -- Adapter contract: one filtered item read per tracked label per tick.
  local hw, kernel = pc_rm_kernel({ input_stock = 5000, output_stock = 200000 })
  local per_tick = nil
  for i = 1, 3 do
    local before = hw.stats.getItemsInNetwork
    kernel:tick()
    local n = hw.stats.getItemsInNetwork - before
    per_tick = per_tick or n
    if n ~= per_tick then per_tick = -1 end
  end
  check("one filtered ME item read per label per tick", per_tick == 2,
    "reads/tick=" .. tostring(per_tick))
end

--------------------------------------------------------------------------------
-- 8. Sensor eu_in parse (display fix)
--------------------------------------------------------------------------------

io.write(dim("\n-- sensor EU/t usage parse --\n"))

do
  local hw = Mock.new({})
  local kernel = Kernel.new({
    machine = hw.machine, computer = hw.computer, event = hw.event,
  })

  hw.set_sensor({
    "Running perfectly.",
    "Currently uses:",
    "1,296 EU/t",
  })
  kernel:tick()
  check("two-line 'Currently uses:' parsed", kernel.cache.eu_input_sensor == 1296,
    "eu_input_sensor=" .. tostring(kernel.cache.eu_input_sensor))

  hw.set_sensor({ "Current Energy Usage: 144 EU/t" })
  kernel:tick()
  check("same-line energy usage parsed", kernel.cache.eu_input_sensor == 144)

  hw.set_sensor({ "Running perfectly.", "Max Energy Income: 2048 EU/t" })
  kernel:tick()
  check("max income line ignored (not usage)", kernel.cache.eu_input_sensor == nil)
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

io.write("\n" .. string.rep("-", 60) .. "\n")
local total = passed + failed
if failed == 0 then
  io.write(bold(green(string.format("All %d Phase 3 checks passed.", total))) .. "\n\n")
  os.exit(0)
else
  io.write(bold(red(string.format("%d/%d checks failed.", failed, total))) .. "\n\n")
  os.exit(1)
end
