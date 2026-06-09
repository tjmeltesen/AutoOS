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
  self.verbose = deps.verbose ~= false -- print emulator-style logs by default

  return self
end

-- Log all sensor lines — structure/maintenance text is often NOT on line 1
-- (line 1 is frequently the machine type id, e.g. industrialelectrolyzer...).
local function log_sensor_lines(cache)
  if type(cache.sensor) ~= "table" or #cache.sensor == 0 then
    print("[Sensor] (no sensor data)")
    return
  end
  for i, raw in ipairs(cache.sensor) do
    print(string.format("[Sensor %d] %s", i, Maintenance.strip_format(raw)))
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

  -- verbose=false silences healthy ticks; always surface faults so silent mode
  -- still shows shutdowns and alarms.
  if self.verbose or result.committed then
    self:log_tick(result)
  end

  return result
end

-- README §5 emulator-style per-tick output.
function Kernel:log_tick(result)
  print(string.format("--- SYSTEM TICK %d ---", self.tick_count))

  local winning = result.intent
  if winning then
    print(string.format("[Maintenance] Fault detected: %s", tostring(winning.reason)))
  end

  -- Requested machine state (what the arbitrator committed, if anything).
  local requested
  if result.requested_state ~= nil then
    requested = tostring(result.requested_state)
  else
    requested = "unchanged"
  end
  print(string.format("[Arbitrator] Requested Machine State: %s", requested))

  if result.committed then
    print(string.format("[Hardware Output] Machine set to ACTIVE = %s",
      tostring(result.requested_state)))
  end

  log_sensor_lines(self.cache)
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
