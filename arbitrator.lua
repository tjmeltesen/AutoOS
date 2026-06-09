--[[
  AutoOS — Validation Arbitrator (sole hardware writer)

  The exclusive gateway authorized to commit changes to physical blocks.
  Logic modules emit abstract intents; the arbitrator flattens them through a
  rigid priority matrix and is the ONLY layer that calls setWorkAllowed().

  Priority matrix (README §3):
    1 — Critical Safety   (maintenance / structure)  -> force shutdown
    2 — Process Integrity (resource soft sleep)       -> Phase 3
    3 — Standard          (process control on/off)    -> Phase 2

  In Phase 1 only the Priority 1 maintenance intent exists.

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

-- Commit the highest-priority intent to hardware.
-- Returns a structured result describing what was done (for logging/tests):
--   { committed = bool, requested_state = bool, intent = intent|nil }
function Arbitrator:commit(intents)
  local intent = select_intent(intents or {})

  -- No intent in Phase 1 means no module requested a change; leave as-is.
  if not intent then
    return { committed = false, requested_state = nil, intent = nil }
  end

  if intent.action == "force_shutdown" then
    self.machine.setWorkAllowed(false)
    if self.computer and self.computer.beep then
      self.computer.beep(800, 2)
    end
    return { committed = true, requested_state = false, intent = intent }
  end

  -- Unknown action: do nothing to hardware, but surface it for logging.
  return { committed = false, requested_state = nil, intent = intent }
end

return Arbitrator
