--[[
  AutoOS — Core Execution Kernel (Phase 1)

  Wires the layered data flow into a single deterministic tick:

    [adapter] poll hardware -> State Cache
        -> [modules] read cache, emit intents
        -> [arbitrator] flatten by priority, commit (sole hardware write)

  Hardware (gt_machine, computer, event) is injected so the exact same code
  runs in-game (require "component"/"computer"/"event") and off-game under a
  desktop Lua interpreter with mocks (README §5).

  References:
    references/opencomputers-libraries.md    (main loop pattern, event.pull)
    references/performance-pitfalls.md         (single poll, <=500ms budget)
    README.md §2, §5                           (layering, emulator output)
]]

local Adapter = require("adapter")
local Arbitrator = require("arbitrator")
local Maintenance = require("modules.maintenance")

local TICK_INTERVAL = 0.5 -- seconds; target overhead <= 500ms

local Kernel = {}
Kernel.__index = Kernel

-- GT appends uptime / tick counters that change every tick and would spam logs.
local NOISY_SENSOR_PATTERNS = {
  "total time",
  "since built",
  "in ticks:",
  "hours,",
  "minutes,",
  "seconds.",
}

local function sensor_line_noisy(raw)
  if type(raw) ~= "string" then return false end
  local lower = Maintenance.strip_format(raw):lower()
  for _, pat in ipairs(NOISY_SENSOR_PATTERNS) do
    if lower:find(pat, 1, true) then return true end
  end
  return false
end

-- deps = { machine = <gt_machine>, computer = <computer>, event = <event> }
function Kernel.new(deps)
  deps = deps or {}
  assert(deps.machine, "Kernel.new: deps.machine (gt_machine proxy) is required")

  local self = setmetatable({}, Kernel)
  self.machine = deps.machine
  self.computer = deps.computer
  self.event = deps.event

  -- Single reused State Cache table (no per-tick allocation).
  self.cache = {}

  self.adapter = Adapter.new(self.machine, self.computer)
  self.arbitrator = Arbitrator.new(self.machine, self.computer)

  -- Logic modules. Order does not matter; the arbitrator resolves priority.
  self.modules = { Maintenance }

  self.tick_count = 0
  -- verbose=true  : log every tick (debug)
  -- verbose=false : silent unless a fault shutdown is committed
  -- monitor=true  : with verbose=false, also log when meaningful state changes
  self.verbose = deps.verbose == true
  self.monitor = deps.monitor == true
  self._prev = {} -- last-tick snapshot for change detection in logs

  return self
end

-- True when any polled hardware field changed since the previous tick.
function Kernel:state_changed(cache)
  local prev = self._prev
  if prev.work_allowed ~= cache.work_allowed then return true end
  if prev.active ~= cache.active then return true end
  if prev.has_work ~= cache.has_work then return true end
  -- Skip eu_input: GT rolling average jitters every tick and causes log spam.
  if type(cache.sensor) == "table" then
    local ps = prev.sensor
    if type(ps) ~= "table" or #ps ~= #cache.sensor then return true end
    for i, line in ipairs(cache.sensor) do
      -- Ignore uptime/tick counters; they tick every cycle and cause log spam.
      if not sensor_line_noisy(line) and line ~= ps[i] then return true end
    end
  end
  return false
end

function Kernel:_remember(cache)
  local snap = self._prev
  snap.work_allowed = cache.work_allowed
  snap.active = cache.active
  snap.has_work = cache.has_work
  snap.eu_input = cache.eu_input
  snap.sensor = cache.sensor
end

-- full_detail=true prints every line (debug). Default: only changed or important lines.
local function log_sensor_lines(cache, prev_sensor, full_detail)
  if type(cache.sensor) ~= "table" or #cache.sensor == 0 then
    print("[Sensor] (no sensor data)")
    return
  end

  local printed = 0
  for i, raw in ipairs(cache.sensor) do
    local clean = Maintenance.strip_format(raw)
    local lower = clean:lower()
    local changed = prev_sensor == nil or raw ~= prev_sensor[i]
    if full_detail or (changed and not sensor_line_noisy(raw)) then
      print(string.format("[Sensor %d] %s", i, clean))
      printed = printed + 1
    end
  end

  if printed == 0 and not full_detail then
    print(string.format("[Sensor] %d lines (no meaningful change)", #cache.sensor))
  end
end

-- Run exactly one logic tick: poll -> evaluate -> commit.
-- Returns the arbitrator result for inspection/tests.
function Kernel:tick()
  self.tick_count = self.tick_count + 1

  self.adapter:poll(self.cache)

  local intents = {}
  for _, mod in ipairs(self.modules) do
    local intent = mod.evaluate(self.cache)
    if intent then
      intents[#intents + 1] = intent
    end
  end

  local result = self.arbitrator:commit(intents)

  local changed = self:state_changed(self.cache)

  if self.verbose or result.committed or (self.monitor and changed) then
    self:log_tick(result, changed)
  end

  self:_remember(self.cache)
  return result
end

-- README §5 emulator-style per-tick output.
function Kernel:log_tick(result, changed)
  print(string.format("--- SYSTEM TICK %d ---", self.tick_count))
  if changed then
    print("[Delta] hardware or sensor reading changed since last tick")
  end

  local c = self.cache
  print(string.format(
    "[Hardware] work_allowed=%s  active=%s  has_work=%s  eu_in=%s",
    tostring(c.work_allowed), tostring(c.active), tostring(c.has_work),
    c.eu_input ~= nil and tostring(c.eu_input) or "n/a"))

  local winning = result.intent
  if winning then
    print(string.format("[Maintenance] Fault detected: %s", tostring(winning.reason)))
  end

  -- "unchanged" here means AutoOS took NO action this tick (not "machine state
  -- is unchanged"). Live machine state is in [Hardware] above.
  if result.committed then
    print(string.format("[Arbitrator] action: force_shutdown -> setWorkAllowed(%s)",
      tostring(result.requested_state)))
  else
    print("[Arbitrator] action: none (no fault matched sensor rules)")
  end

  -- verbose=true dumps all sensor lines; false = compact (changed/important only).
  log_sensor_lines(self.cache, self._prev.sensor, self.verbose)
end

-- Timed main loop. maxTicks bounds the loop for desktop tests; pass nil for an
-- infinite in-game loop. Uses computer.uptime()/event.pull for tick pacing.
function Kernel:run(maxTicks)
  while true do
    local t0 = self.computer and self.computer.uptime() or 0
    self:tick()

    if maxTicks and self.tick_count >= maxTicks then
      break
    end

    if self.computer and self.event then
      local elapsed = self.computer.uptime() - t0
      local remaining = TICK_INTERVAL - elapsed
      if remaining > 0 then
        self.event.pull(remaining)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- In-game entry point.
--
-- When this file is executed directly inside OpenComputers, build real deps
-- from the OC libraries and start the loop. Under a desktop Lua interpreter
-- those requires fail (no such modules), so the file is simply usable as a
-- module via require("main") for tests.
-- ---------------------------------------------------------------------------
local function build_oc_deps()
  local ok_c, component = pcall(require, "component")
  local ok_comp, computer = pcall(require, "computer")
  local ok_e, event = pcall(require, "event")
  if not (ok_c and ok_comp and ok_e) then
    return nil
  end
  return {
    machine = component.gt_machine,
    computer = computer,
    event = event,
  }
end

-- Detect "run as main script" vs "loaded as a module".
-- arg is set for the top-level script; pcall(require, ...) guards desktop use.
if arg and arg[0] and arg[0]:find("main%.lua$") then
  local deps = build_oc_deps()
  if deps then
    print("=== Starting AutoOS Desktop Validation Emulator ===")
    Kernel.new(deps):run()
    print("=== Simulation Complete ===")
  else
    io.stderr:write(
      "AutoOS main.lua: OpenComputers libraries not found.\n" ..
      "This file is meant to run in-game. For desktop validation run:\n" ..
      "  lua tests/phase1_test.lua\n")
  end
end

return Kernel
