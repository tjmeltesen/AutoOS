--[[
  AutoOS — Orchestrator FSM (coordinator, no lane hardware)

  The orchestrator does NOT watch the subnet or dispatch jobs. The broker OC
  on the subnet watches ME storage, resolves deliveries, runs lanes, and sends:
    SUBNET_DELIVERY — delivery detected, job starting
    BROKER_STATUS   — dispatching / running / recovering / complete / failed
    CRAFT_DONE      — job finished

  Optional (Phase 4): TRIGGER_CRAFT from overseer for main-net AE requests.
]]

local Protocols = require("network_protocols")

local Orchestrator = {}
Orchestrator.__index = Orchestrator

function Orchestrator.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Orchestrator)
  self.config = deps.config or error("Orchestrator.new: config required")
  self.registry = deps.registry or error("Orchestrator.new: registry required")
  self.link = deps.link or error("Orchestrator.new: link required")
  self.now = deps.now or function() return 0 end
  self._log = deps.log or function() end

  local cfg = self.config
  self.subnet_id = cfg.subnet_id
  self.broker_address = (cfg.broker_address ~= "" and cfg.broker_address) or nil

  self.state = "idle"
  self.jobs = {}  -- job_id -> { recipe_key, display_name, volume_mB, phase, ... }
  return self
end

function Orchestrator:log(msg)
  self._log("[Orchestrator] " .. msg)
end

function Orchestrator:_track_job(pkt, from)
  local row = self.registry:get(pkt.recipe_key)
    or self.registry:resolve_uid(pkt.recipe_uid)
  local display = row and (row.display_name or row.recipe_key) or pkt.recipe_key
  self.jobs[pkt.job_id] = {
    job_id = pkt.job_id,
    recipe_key = pkt.recipe_key,
    recipe_uid = pkt.recipe_uid,
    display_name = display,
    volume_mB = pkt.volume_mB,
    phase = "detected",
    broker = from,
    started = self:now(),
  }
  self.state = "tracking"
end

function Orchestrator:tick()
  return self.state
end

function Orchestrator:on_message(from, message)
  local pkt = Protocols.parse(message)
  if not pkt then return end
  local K = Protocols.KIND

  if from and not self.broker_address then self.broker_address = from end

  if pkt.kind == K.SUBNET_DELIVERY then
    self:_on_subnet_delivery(pkt, from)
  elseif pkt.kind == K.BROKER_STATUS then
    self:_on_status(pkt)
  elseif pkt.kind == K.CRAFT_DONE then
    self:_on_craft_done(pkt)
  elseif pkt.kind == K.CRAFT_FAIL then
    self:_on_craft_fail(pkt)
  elseif pkt.kind == K.BROKER_EVENT then
    self:_on_broker_event(pkt)
  elseif pkt.kind == K.TRIGGER_CRAFT then
    self:log("TRIGGER_CRAFT received — Phase 4 overseer not wired yet")
  end
end

function Orchestrator:_on_subnet_delivery(pkt, from)
  self:_track_job(pkt, from)
  self:log(string.format(
    "subnet delivery: %s %dmB uid=%s job=%s (source=%s)",
    pkt.recipe_key, pkt.volume_mB or 0, tostring(pkt.recipe_uid),
    pkt.job_id, tostring(pkt.source)
  ))
  if self.broker_address and self.link then
    self.link:send(self.broker_address, Protocols.delivery_ack(pkt.job_id, self.subnet_id))
  end
  self.link:broadcast(Protocols.broker_event(
    self.subnet_id, Protocols.EVENT.DISPATCH_START,
    self.jobs[pkt.job_id].display_name, pkt.volume_mB or 0, pkt.job_id
  ))
end

function Orchestrator:_on_status(pkt)
  local job = self.jobs[pkt.job_id]
  if not job then
    self:log(string.format("status %s for unknown job %s", pkt.phase, pkt.job_id))
    return
  end
  job.phase = pkt.phase
  if pkt.phase == Protocols.PHASE.DISPATCHING then
    self:log("job " .. pkt.job_id .. " dispatching lanes")
  elseif pkt.phase == Protocols.PHASE.RUNNING then
    self:log("job " .. pkt.job_id .. " running — " .. tostring(pkt.detail))
  elseif pkt.phase == Protocols.PHASE.RECOVERING then
    self:log("job " .. pkt.job_id .. " recovering circuits")
  elseif pkt.phase == Protocols.PHASE.COMPLETE then
    self:log("job " .. pkt.job_id .. " complete")
  elseif pkt.phase == Protocols.PHASE.FAILED then
    self:log("job " .. pkt.job_id .. " FAILED: " .. tostring(pkt.detail))
  end
end

function Orchestrator:_on_craft_done(pkt)
  local job = self.jobs[pkt.job_id]
  if job then
    self.link:broadcast(Protocols.broker_event(
      self.subnet_id, Protocols.EVENT.JOB_COMPLETE, job.display_name, 0, pkt.job_id
    ))
    self:log("job complete: " .. pkt.job_id)
    self.jobs[pkt.job_id] = nil
  end
  if not next(self.jobs) then self.state = "idle" end
end

function Orchestrator:_on_craft_fail(pkt)
  local job = self.jobs[pkt.job_id]
  if job then
    self.link:broadcast(Protocols.broker_event(
      self.subnet_id, Protocols.EVENT.JOB_FAILED, job.display_name, 0, pkt.job_id
    ))
    self:log("job FAILED: " .. pkt.job_id .. " — " .. tostring(pkt.detail))
    self.jobs[pkt.job_id] = nil
  end
  if not next(self.jobs) then self.state = "idle" end
end

function Orchestrator:_on_broker_event(pkt)
  if pkt.event == Protocols.EVENT.DISPATCH_START then
    self:log(string.format("broker event: dispatch %s %dmB", pkt.label, pkt.volume or 0))
  end
end

return Orchestrator
