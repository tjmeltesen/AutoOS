--[[
  AutoOS — Core Execution Kernel (Phases 1-2)

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
local ProcessControl = require("modules.process_control")
local Display = require("display")

local TICK_INTERVAL = 0.5 -- seconds; target overhead <= 500ms

local Kernel = {}
Kernel.__index = Kernel

-- Collapse time-varying craft skip messages so logs/display keys do not fire every tick.
local function stable_craft_reason(reason)
  if not reason then return nil end
  if reason:match("^craft job still active") then
    return "craft job still active"
  end
  if reason:match("^cooldown") then
    return "cooldown (awaiting stock update)"
  end
  if reason:match("^no machine power") then
    return "no machine power"
  end
  return reason
end

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

-- deps = {
--   machine = <gt_machine>, computer = <computer>, event = <event>,
--   me = <me_interface|me_controller>,              -- optional (Phase 2)
--   process_control = { label, low, high, kind },   -- optional (Phase 2)
--   gpu = <gpu>, screen = <screen address>,         -- optional read-only monitor
-- }
function Kernel.new(deps)
  deps = deps or {}
  assert(deps.machine, "Kernel.new: deps.machine (gt_machine proxy) is required")

  local self = setmetatable({}, Kernel)
  self.machine = deps.machine
  self.computer = deps.computer
  self.event = deps.event
  self.me = deps.me

  -- Single reused State Cache table (no per-tick allocation).
  self.cache = {}

  -- Phase 2 process-control target(s) the adapter must poll inventory for.
  local targets = {}
  if self.me and deps.process_control then
    targets[#targets + 1] = {
      label = deps.process_control.label,
      craft_label = deps.process_control.craft_label,
      kind = deps.process_control.kind or "item",
    }
  end

  self.adapter = Adapter.new(self.machine, self.computer, self.me, targets)
  self.arbitrator = Arbitrator.new(self.machine, self.computer, self.me)

  -- Logic modules. Order does not matter; the arbitrator resolves priority.
  -- maintenance=false skips gt_machine fault shutdown (use for ME-only craft when
  -- a connected multiblock has unrelated maintenance issues).
  self.modules = {}
  if deps.maintenance ~= false then
    self.modules[#self.modules + 1] = Maintenance
  end

  -- Phase 2: enable the hysteresis leveling engine only when an ME proxy and a
  -- product config are wired in. Without them, the kernel runs Phase 1 only.
  self.process_control = nil
  if self.me and deps.process_control then
    self.process_control = ProcessControl.new(deps.process_control)
    self.modules[#self.modules + 1] = self.process_control
  end

  -- Optional read-only status display. Built only when a gpu proxy is provided;
  -- failures are isolated so the control loop never depends on the screen.
  self.display = nil
  if deps.gpu then
    local ok, disp = pcall(Display.new, deps.gpu, deps.screen)
    if ok then
      self.display = disp
    else
      io.stderr:write("AutoOS: display init failed, continuing headless: "
        .. tostring(disp) .. "\n")
    end
  end

  self.tick_count = 0
  -- verbose=true  : log every tick (debug)
  -- verbose=false : silent unless a fault shutdown is committed
  -- monitor=true  : with verbose=false, also log when meaningful state changes
  self.verbose = deps.verbose == true
  self.monitor = deps.monitor == true
  self._prev = {} -- last-tick snapshot for change detection in logs
  self._prev_craft_reason = nil -- suppress repeated craft-skip log spam
  self._prev_display_key = nil
  self._prev_fault = nil -- last maintenance fault reason, for transition logging
  self._prev_power_ok = nil -- power-available transition logging

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
    local out = mod.evaluate(self.cache)
    if out then
      -- Modules may return one intent or an array (process control: machine + craft).
      if out.priority then
        intents[#intents + 1] = out
      else
        for _, intent in ipairs(out) do
          intents[#intents + 1] = intent
        end
      end
    end
  end

  local result = self.arbitrator:commit(intents, self.cache)

  local changed = self:state_changed(self.cache)

  -- Log craft skips only when the stable reason changes (avoids terminal spam).
  local craft_reason = result.craft and result.craft.craft_reason
  local stable_reason = stable_craft_reason(craft_reason)
  local craft_reason_changed = stable_reason ~= self._prev_craft_reason
  if craft_reason_changed then
    self._prev_craft_reason = stable_reason
  end

  -- Maintenance fault is active whenever its intent wins — not just on the tick
  -- the shutdown commits (change-only writes make later ticks commit nothing).
  local fault = nil
  if result.intent and result.intent.module == "maintenance" then
    fault = result.intent.reason
  end
  local fault_changed = fault ~= self._prev_fault
  self._prev_fault = fault

  local power_ok = not (self.cache.power_loss or self.cache.power_available == false)
  if self._prev_power_ok ~= nil and power_ok ~= self._prev_power_ok then
    if power_ok then
      print("AutoOS: machine power restored")
    else
      print("AutoOS: POWER LOSS - withholding machine ON and ME crafts")
    end
  end
  self._prev_power_ok = power_ok

  -- Fault transitions always print (safety-critical), even with a display bound.
  if fault_changed then
    if fault then
      print(string.format("AutoOS: MAINTENANCE FAULT - %s (crafting suppressed)",
        tostring(fault)))
    else
      print("AutoOS: maintenance fault cleared")
    end
  end

  -- Console logs scroll the shared screen and fight the status panel, so they
  -- stay quiet while a display is bound (verbose=true overrides for debugging).
  local logging = self.verbose or not self.display
  if logging and (self.verbose or result.committed or craft_reason_changed
      or (self.monitor and changed)) then
    self:log_tick(result, changed)
  end

  -- Read-only status panel. Isolated in a pcall: a display error must never
  -- prevent the safety/control loop from completing the tick. Full re-render
  -- only on state change; otherwise just the tick counter row is refreshed.
  if self.display then
    local snap = self:_snapshot(result, fault)
    local key = self:_display_key(snap)
    local ok, err
    if key ~= self._prev_display_key then
      self._prev_display_key = key
      ok, err = pcall(function() self.display:render(snap) end)
    else
      ok, err = pcall(function() self.display:update_tick(snap.tick) end)
    end
    if not ok then
      io.stderr:write("AutoOS: display render error: " .. tostring(err) .. "\n")
      self.display = nil
    end
  end

  self:_remember(self.cache)
  return result
end

-- Build the plain snapshot table the read-only Display consumes. Pulls only
-- from the already-computed cache + arbitrator result (no hardware access).
-- fault: active maintenance fault reason (nil when healthy), computed in tick().
function Kernel:_snapshot(result, fault)
  local c = self.cache
  local pc = nil
  if self.process_control then
    local p = self.process_control
    pc = {
      label = p.label,
      stock = c.stock and c.stock[p.label] or nil,
      active = p.active,
      low = p.low,
      high = p.high,
      mode = p.mode,
      craftable = c.craftable and c.craftable[p.label] or false,
      craft = result.craft,
    }
  end

  return {
    tick = self.tick_count,
    work_allowed = c.work_allowed,
    active = c.active,
    has_work = c.has_work,
    eu_input = c.eu_input,
    stored_eu = c.stored_eu,
    power_available = c.power_available,
    power_loss = c.power_loss,
    pc = pc,
    action = result.action,
    committed = result.committed,
    requested_state = result.requested_state,
    fault = fault,
    craft_reason = result.craft and result.craft.craft_reason or nil,
  }
end

-- Stable key for display refresh. Excludes the tick counter and eu_input: GT's
-- rolling EU average jitters every tick and would force a full redraw each cycle.
function Kernel:_display_key(snap)
  if not snap then return "" end
  local pc = snap.pc
  local pc_key = ""
  if pc then
    pc_key = string.format("%s|%s|%s|%s|%s|%s",
      tostring(pc.stock), tostring(pc.active), tostring(pc.mode),
      tostring(pc.craftable), tostring(pc.craft and pc.craft.committed),
      tostring(stable_craft_reason(snap.craft_reason)))
  end
  return string.format("%s|%s|%s|%s|%s|%s|%s",
    tostring(snap.work_allowed), tostring(snap.active), tostring(snap.has_work),
    tostring(snap.fault), tostring(snap.power_available), tostring(snap.power_loss),
    pc_key)
end

-- README §5 emulator-style per-tick output.
function Kernel:log_tick(result, changed)
  print(string.format("--- SYSTEM TICK %d ---", self.tick_count))
  if changed then
    print("[Delta] hardware or sensor reading changed since last tick")
  end

  local c = self.cache
  print(string.format(
    "[Hardware] work_allowed=%s  active=%s  has_work=%s  eu_in=%s  stored=%s  power=%s",
    tostring(c.work_allowed), tostring(c.active), tostring(c.has_work),
    c.eu_input ~= nil and tostring(c.eu_input) or "n/a",
    c.stored_eu ~= nil and tostring(c.stored_eu) or "n/a",
    (c.power_loss or c.power_available == false) and "LOSS" or "OK"))

  -- Process-control telemetry: tracked stock + the hysteresis state requested.
  if self.process_control then
    local pc = self.process_control
    local stock = c.stock and c.stock[pc.label]
    local craftable = c.craftable and c.craftable[pc.label]
    print(string.format("[Process Control] %s stock=%s -> %s (low=%d high=%d mode=%s craftable=%s)",
      pc.label, stock ~= nil and tostring(stock) or "n/a",
      pc.active and "ACTIVE" or "IDLE", pc.low, pc.high, pc.mode,
      craftable and "yes" or "no"))
  end

  local winning = result.intent
  if winning then
    if winning.module == "maintenance" then
      print(string.format("[Maintenance] Fault detected: %s", tostring(winning.reason)))
    else
      print(string.format("[%s] %s", tostring(winning.module), tostring(winning.reason)))
    end
  end

  -- "action: none" here means AutoOS wrote nothing to hardware this tick (either
  -- no intent won, or the machine was already in the requested state). Live
  -- machine state is in [Hardware] above.
  if result.machine and result.machine.committed then
    print(string.format("[Arbitrator] action: %s -> setWorkAllowed(%s)",
      tostring(result.machine.action), tostring(result.machine.requested_state)))
  end
  if result.craft then
    if result.craft.committed then
      print(string.format("[Arbitrator] action: request_craft %s x%d",
        tostring(result.craft.craft_label), result.craft.craft_amount or 0))
    elseif result.craft.craft_reason then
      print(string.format("[Arbitrator] craft skipped: %s", result.craft.craft_reason))
    end
  end
  if not result.committed then
    print("[Arbitrator] action: none (no hardware change required)")
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

  -- Phase 2: bind an ME proxy if one is connected (interface preferred, then
  -- controller). Process control stays disabled until both a proxy and a
  -- product config exist — edit the config block to match your line.
  local me = nil
  if component.isAvailable and component.isAvailable("me_interface") then
    me = component.me_interface
  elseif component.isAvailable and component.isAvailable("me_controller") then
    me = component.me_controller
  end

  -- Optional read-only status monitor: bind the GPU to a screen when both exist.
  local gpu, screen = nil, nil
  if component.isAvailable and component.isAvailable("gpu")
     and component.isAvailable("screen") then
    gpu = component.gpu
    screen = component.screen.address
  end

  -- No process_control config here: product/band setup lives in start.lua,
  -- the real in-game entry point. Running main.lua directly gives Phase 1 only.
  return {
    machine = component.gt_machine,
    computer = computer,
    event = event,
    me = me,
    gpu = gpu,
    screen = screen,
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
