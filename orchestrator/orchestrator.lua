--[[
  AutoOS — Orchestrator health aggregator

  Collects lane-level health telemetry from broker OCs and keeps an in-memory
  snapshot for display/logging. No recipe dispatch responsibilities.
]]

local Protocols = require("network_protocols")

local Orchestrator = {}
Orchestrator.__index = Orchestrator

function Orchestrator.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Orchestrator)
  self.config = deps.config or error("Orchestrator.new: config required")
  self.link = deps.link or error("Orchestrator.new: link required")
  self.now = deps.now or function() return 0 end
  self._log = deps.log or function() end
  self.brokers = {} -- subnet_id -> { lanes = { [machine_id] = {...} }, last_event = {...} }
  return self
end

function Orchestrator:log(msg)
  self._log("[Orchestrator] " .. msg)
end

function Orchestrator:_broker(subnet_id)
  local row = self.brokers[subnet_id]
  if row then return row end
  row = { lanes = {}, last_event = nil, updated = self:now() }
  self.brokers[subnet_id] = row
  return row
end

function Orchestrator:_on_health(pkt, from)
  local broker = self:_broker(pkt.subnet_id or "unknown")
  broker.updated = self:now()
  local lane = broker.lanes[pkt.machine_id] or {}
  lane.state = pkt.state
  lane.detail = pkt.detail
  lane.from = from
  lane.updated = broker.updated
  broker.lanes[pkt.machine_id] = lane

  self:log(string.format("health %s/%s state=%s detail=%s",
    tostring(pkt.subnet_id), tostring(pkt.machine_id), tostring(pkt.state), tostring(pkt.detail)))
end

function Orchestrator:_on_event(pkt, from)
  local broker = self:_broker(pkt.subnet_id or "unknown")
  broker.updated = self:now()
  broker.last_event = {
    event = pkt.event,
    label = pkt.label,
    detail = pkt.job_id,
    from = from,
    at = broker.updated,
  }
  self:log(string.format("event %s/%s label=%s detail=%s",
    tostring(pkt.subnet_id), tostring(pkt.event), tostring(pkt.label), tostring(pkt.job_id)))
end

function Orchestrator:on_message(from, message)
  local pkt = Protocols.parse(message)
  if not pkt then return end
  local K = Protocols.KIND
  if pkt.kind == K.BROKER_HEALTH then
    self:_on_health(pkt, from)
  elseif pkt.kind == K.BROKER_EVENT then
    self:_on_event(pkt, from)
  end
end

function Orchestrator:tick()
  return self.brokers
end

return Orchestrator
