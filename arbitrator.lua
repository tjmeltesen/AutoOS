--[[
  AutoOS — Validation Arbitrator (sole hardware writer)

  The exclusive gateway authorized to commit changes to physical blocks and the
  ME network. Logic modules emit abstract intents; the arbitrator flattens them
  through a rigid priority matrix and is the ONLY layer that calls
  setWorkAllowed() or issues ME craft requests.

  Priority matrix (README §3):
    1 — Critical Safety   (maintenance / structure)  -> force shutdown
    2 — Process Integrity (resource soft sleep)       -> Phase 3
    3 — Standard          (process control)           -> machine on/off, ME craft

  All intents at the winning priority level are committed (e.g. both
  set_work_allowed and request_craft when mode = "both"). Lower-priority
  intents are suppressed when a higher priority wins.

  Change-only writes: setWorkAllowed() is called only when the requested state
  differs from cache.work_allowed.   ME crafts are throttled three ways:
    1) while AECraftingJob reports not done — but an idle gt_machine clears the
       job once the dispatch grace period has passed (phantom-job recovery);
    2) cooldown after a committed request (stock may lag in getFluidsInNetwork);
    3) until polled stock rises above the level seen at the last request.
  This prevents back-to-back duplicate orders (e.g. 200k + 200k = 400k) while
  still pipelining the next max_craft batch when the machine is free.

  References:
    references/autoos-api-mapping.md         (arbitrator commits crafts + machine)
    references/me-network-api.md              (getCraftables, request, job status)
    references/maintenance-and-safety.md      (Priority 1 response: shutdown + beep)
]]

local Arbitrator = {}
Arbitrator.__index = Arbitrator

-- machine  : gt_machine proxy (real or mock)
-- computer : computer library (real or mock) — used for the audio alarm
-- me       : ME network proxy (optional) — required for request_craft commits
function Arbitrator.new(machine, computer, me)
  assert(machine, "Arbitrator.new: a gt_machine proxy is required")
  local self = setmetatable({}, Arbitrator)
  self.machine = machine
  self.computer = computer
  self.me = me
  self.craft_jobs = {} -- craft label -> AECraftingJob (or mock)
  self.craft_state = {} -- craft label -> { time, stock_at_request, amount }
  self.craft_cooldown = 10 -- seconds between requests unless stock increased
  self.craft_job_timeout = 120 -- seconds; stale ME jobs are cleared (power loss / stuck craft)
  -- ME needs time to compute the job and push ingredients into the machine.
  -- An idle machine only proves the job is finished/dead after this grace, or
  -- duplicate batches fire every tick during dispatch (overcraft).
  self.craft_dispatch_grace = 15 -- seconds
  return self
end

-- Machine is idle: not running and no recipe/work in progress. After the
-- dispatch grace, an idle machine means the tracked ME job is finished or dead
-- (e.g. isDone never fires after power loss) and must not block the next batch.
local function machine_idle(cache)
  if not cache then return false end
  if cache.active == true then return false end
  if cache.has_work == true then return false end
  return true
end

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

-- True when no active craft job blocks a new request for this label.
-- Stale jobs (ME stuck after power loss, long isComputing) are cleared after the
-- hard timeout, or earlier when the gt_machine sits idle past the dispatch grace.
function Arbitrator:_craft_slot_available(label, cache)
  local job = self.craft_jobs[label]
  if not job then return true end

  local state = self.craft_state[label]
  if state and self.computer and self.computer.uptime then
    local age = self.computer.uptime() - (state.time or 0)
    if age >= self.craft_job_timeout then
      self.craft_jobs[label] = nil
      return true
    end
    if age >= self.craft_dispatch_grace and machine_idle(cache) then
      self.craft_jobs[label] = nil
      return true
    end
  end

  if job.isDone and job.isDone() then
    self.craft_jobs[label] = nil
    return true
  end
  if job.hasFailed and job.hasFailed() then
    self.craft_jobs[label] = nil
    return true
  end
  if job.isCanceled and job.isCanceled() then
    self.craft_jobs[label] = nil
    return true
  end
  return false
end

function Arbitrator:_commit_work_allowed(target, intent, cache)
  -- Defense in depth: never re-enable into a power-failed line (GT self-pauses).
  if target == true and cache and (cache.power_loss or cache.power_available == false) then
    return {
      committed = false,
      requested_state = target,
      action = intent.action,
      intent = intent,
      machine_reason = "no machine power (eu_in=0, stored=0 or power loss)",
    }
  end

  local current = cache and cache.work_allowed
  if cache ~= nil and current == target then
    return {
      committed = false,
      requested_state = target,
      action = intent.action,
      intent = intent,
    }
  end

  self.machine.setWorkAllowed(target)

  if intent.action == "force_shutdown" and self.computer and self.computer.beep then
    self.computer.beep(800, 2)
  end

  return {
    committed = true,
    requested_state = target,
    action = intent.action,
    intent = intent,
  }
end

function Arbitrator:_commit_craft(intent, cache)
  if not self.me or not self.me.getCraftables then
    return {
      committed = false,
      action = "request_craft",
      intent = intent,
      craft_reason = "no ME proxy wired",
    }
  end

  local label = intent.label
  local amount = intent.amount or 0
  if amount <= 0 then
    return { committed = false, action = "request_craft", intent = intent }
  end

  if cache and (cache.power_loss or cache.power_available == false) then
    return {
      committed = false,
      action = "request_craft",
      intent = intent,
      craft_reason = "no machine power (eu_in=0, stored=0 or power loss)",
    }
  end

  if not self:_craft_slot_available(label, cache) then
    local state = self.craft_state[label]
    local waiting = state and self.computer and self.computer.uptime
      and (self.computer.uptime() - (state.time or 0)) or 0
    return {
      committed = false,
      action = "request_craft",
      intent = intent,
      craft_reason = string.format(
        "craft job still active (%.0fs / %ds timeout)",
        waiting, self.craft_job_timeout),
    }
  end

  -- Cooldown: ME stock polling can lag behind a finished job, causing a second
  -- full-deficit request before fluid counts update (200k + 200k = 400k).
  local stock_key = intent.stock_label or label
  local stock_now = cache and cache.stock and cache.stock[stock_key]
  local prev = self.craft_state[label]
  if prev and self.computer and self.computer.uptime then
    local elapsed = self.computer.uptime() - prev.time
    local stock_stale = stock_now == nil or stock_now <= prev.stock_at_request
    if elapsed < self.craft_cooldown and stock_stale then
      return {
        committed = false,
        action = "request_craft",
        intent = intent,
        craft_reason = string.format(
          "cooldown %.0fs (awaiting stock update)", self.craft_cooldown - elapsed),
      }
    end
  end

  local crafts = self.me.getCraftables({ label = label })
  if type(crafts) ~= "table" or #crafts == 0 then
    return {
      committed = false,
      action = "request_craft",
      intent = intent,
      craft_reason = "no ME recipe for label",
    }
  end

  local craftable = crafts[1]
  if not craftable or not craftable.request then
    return {
      committed = false,
      action = "request_craft",
      intent = intent,
      craft_reason = "craftable has no request()",
    }
  end

  local job = craftable.request(amount, intent.prioritize_power ~= false)
  self.craft_jobs[label] = job
  self.craft_state[label] = {
    time = self.computer and self.computer.uptime and self.computer.uptime() or 0,
    stock_at_request = stock_now or intent.stock or 0,
    amount = amount,
  }

  return {
    committed = true,
    action = "request_craft",
    intent = intent,
    craft_label = label,
    craft_amount = amount,
  }
end

-- Commit all intents at the winning priority level.
-- Returns a structured result for logging/tests.
function Arbitrator:commit(intents, cache)
  local winner = select_intent(intents or {})
  if not winner then
    return {
      committed = false,
      requested_state = nil,
      action = nil,
      intent = nil,
      craft = nil,
    }
  end

  local win_priority = winner.priority
  local any_committed = false
  local machine_result = nil
  local craft_result = nil

  for _, intent in ipairs(intents or {}) do
    if intent.priority == win_priority then
      if intent.action == "force_shutdown" then
        machine_result = self:_commit_work_allowed(false, intent, cache)
        if machine_result.committed then any_committed = true end
      elseif intent.action == "set_work_allowed" then
        machine_result = self:_commit_work_allowed(intent.state, intent, cache)
        if machine_result.committed then any_committed = true end
      elseif intent.action == "request_craft" then
        craft_result = self:_commit_craft(intent, cache)
        if craft_result.committed then any_committed = true end
      end
    end
  end

  return {
    committed = any_committed,
    requested_state = machine_result and machine_result.requested_state,
    action = machine_result and machine_result.action or craft_result and craft_result.action,
    intent = winner,
    craft = craft_result,
    machine = machine_result,
  }
end

return Arbitrator
