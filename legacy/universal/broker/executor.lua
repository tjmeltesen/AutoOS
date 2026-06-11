--[[
  Universal Craft Brokers — job executor (sole hardware writer on broker PC).

  Completion requires: AE job done AND machine idle AND grace period elapsed.
]]

local Executor = {}
Executor.__index = Executor

local PHASE_CRAFTING = "crafting"
local PHASE_WAIT_IDLE = "waiting_idle"
local PHASE_GRACE = "grace"

function Executor.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Executor)
  self.registry = deps.registry
  self.me = deps.me
  self.computer = deps.computer
  self.grace_seconds = deps.grace_seconds or 15
  self.job = nil
  return self
end

function Executor:busy()
  return self.job ~= nil
end

function Executor:current_job()
  return self.job
end

function Executor:start(job_id, machine_id, label, amount)
  if self.job then
    return false, "broker_busy"
  end

  local proxy = self.registry:get_proxy(machine_id)
  if not proxy then
    return false, "no_proxy"
  end

  if proxy.setWorkAllowed then
    proxy.setWorkAllowed(true)
  end

  local craft_job
  if self.me and self.me.getCraftables then
    local crafts = self.me.getCraftables({ label = label })
    if type(crafts) ~= "table" or #crafts == 0 or not crafts[1].request then
      return false, "no_me_recipe"
    end
    craft_job = crafts[1].request(amount, true)
  else
    return false, "no_me_proxy"
  end

  self.job = {
    job_id = job_id,
    machine_id = machine_id,
    label = label,
    amount = amount,
    phase = PHASE_CRAFTING,
    craft_job = craft_job,
    ae_done_at = nil,
    idle_since = nil,
  }
  return true
end

local function machine_idle(state)
  if type(state) ~= "table" or not state.available then
    return false
  end
  if state.maintenance_fault then
    return false
  end
  if state.active then
    return false
  end
  if state.has_work then
    return false
  end
  return true
end

local function ae_job_failed(job)
  if not job or not job.craft_job then
    return true
  end
  local cj = job.craft_job
  if cj.hasFailed and cj.hasFailed() then return true end
  if cj.isCanceled and cj.isCanceled() then return true end
  return false
end

local function ae_job_done(job)
  if not job or not job.craft_job then
    return false
  end
  local cj = job.craft_job
  if cj.isDone and cj.isDone() then
    return true
  end
  return false
end

function Executor:tick(cache)
  local job = self.job
  if not job then
    return nil
  end

  if ae_job_failed(job) then
    local failed = job
    self.job = nil
    return { event = "fail", job_id = failed.job_id, reason = "ae_job_failed" }
  end

  local state = cache and cache.machines and cache.machines[job.machine_id]
  local now = self.computer and self.computer.uptime and self.computer.uptime() or 0

  if job.phase == PHASE_CRAFTING then
    if ae_job_done(job) then
      job.ae_done_at = now
      job.phase = PHASE_WAIT_IDLE
    end
    return nil
  end

  if job.phase == PHASE_WAIT_IDLE then
    if machine_idle(state) then
      job.idle_since = job.idle_since or now
      job.phase = PHASE_GRACE
    end
    return nil
  end

  if job.phase == PHASE_GRACE then
    if not machine_idle(state) then
      -- Machine started again; wait until idle before grace counts.
      job.phase = PHASE_WAIT_IDLE
      job.idle_since = nil
      return nil
    end
    local anchor = job.ae_done_at or now
    if (now - anchor) >= self.grace_seconds then
      local done = job
      self.job = nil
      return {
        event = "done",
        job_id = done.job_id,
        machine_id = done.machine_id,
      }
    end
  end

  return nil
end

return Executor
