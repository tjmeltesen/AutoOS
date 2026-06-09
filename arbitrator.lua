--[[
  AutoOS — Validation Arbitrator (sole hardware writer)

  The exclusive gateway authorized to commit changes to physical blocks.
  Logic modules emit abstract intents; the arbitrator flattens them through a
  rigid priority matrix and is the ONLY layer that calls setWorkAllowed().

  Priority matrix (README §3):
    1 — Critical Safety   (maintenance / structure)  -> force shutdown
    2 — Process Integrity (resource soft sleep)       -> Phase 3
    3 — Standard          (process control on/off)    -> Phase 2

  Change-only writes: setWorkAllowed() is called only when the requested state
  differs from the machine's current work_allowed (read from the cache). This
  avoids redundant per-tick packet writes when process control simply holds a
  steady state (performance-pitfalls.md component-call budget).

  References:
    references/autoos-api-mapping.md         (arbitrator is sole setWorkAllowed caller)
    references/maintenance-and-safety.md      (Priority 1 response: shutdown + beep)
]]

local Arbitrator = {}
Arbitrator.__index = Arbitrator

-- machine  : gt_machine proxy (real or mock)
-- computer : computer library (real or mock) — used for the audio alarm
function Arbitrator.new(machine, computer)
  assert(machine, "Arbitrator.new: a gt_machine proxy is required")
  local self = setmetatable({}, Arbitrator)
  self.machine = machine
  self.computer = computer
  return self
end

-- Select the winning intent: lowest numeric priority wins (1 overrides 2/3).
local function select_intent(intents)
  local winner = nil
  for _, intent in ipairs(intents) do
    if intent and intent.priority then
      if not winner or intent.priority < winner.priority then
        winner = intent
      end
    end
  end
  return winner
end

-- Resolve the hardware work_allowed state a winning intent requests.
-- Returns the desired boolean, or nil for actions that aren't on/off control.
local function desired_state(intent)
  if intent.action == "force_shutdown" then
    return false
  elseif intent.action == "set_work_allowed" then
    return intent.state
  end
  return nil
end

-- Commit the highest-priority intent to hardware.
-- cache (optional) provides the current work_allowed for change-only writes;
-- when omitted (e.g. a direct call) the write is always performed.
-- Returns a structured result describing what was done (for logging/tests):
--   { committed = bool, requested_state = bool|nil, action = string|nil, intent = intent|nil }
function Arbitrator:commit(intents, cache)
  local intent = select_intent(intents or {})

  -- No intent means no module requested a change; leave hardware as-is.
  if not intent then
    return { committed = false, requested_state = nil, action = nil, intent = nil }
  end

  local target = desired_state(intent)

  -- Unknown action: do nothing to hardware, but surface it for logging.
  if target == nil then
    return { committed = false, requested_state = nil, action = intent.action, intent = intent }
  end

  -- Change-only: skip the write when the machine is already in the target state.
  local current = cache and cache.work_allowed
  if cache ~= nil and current == target then
    return { committed = false, requested_state = target, action = intent.action, intent = intent }
  end

  self.machine.setWorkAllowed(target)

  -- Audio alarm only on a Priority 1 shutdown that actually flips the machine off.
  if intent.action == "force_shutdown" and self.computer and self.computer.beep then
    self.computer.beep(800, 2)
  end

  return { committed = true, requested_state = target, action = intent.action, intent = intent }
end

return Arbitrator
