--[[
  Universal Craft Brokers — coordinator modem client (broadcast craft_req).
]]

local Protocol = require("shared.protocol")

local BrokerClient = {}
BrokerClient.__index = BrokerClient

function BrokerClient.new(deps)
  deps = deps or {}
  local self = setmetatable({}, BrokerClient)
  self.modem = deps.modem
  self.modem_port = deps.modem_port or 4410
  self.brokers = deps.brokers or {}
  self.computer = deps.computer
  self.in_flight = {}
  self.jobs = {}
  self.seq = 0
  self.log = deps.log or function() end
  return self
end

function BrokerClient:open_modem()
  if self.modem and self.modem.open then
    self.modem.open(self.modem_port)
  end
end

function BrokerClient:_next_job_id(label)
  self.seq = self.seq + 1
  local uptime = self.computer and self.computer.uptime and self.computer.uptime() or 0
  return string.format("%s:%d:%.0f", label, self.seq, uptime)
end

function BrokerClient:label_in_flight(label)
  return self.in_flight[label] ~= nil
end

function BrokerClient:get_in_flight_labels()
  local labels = {}
  for label, _ in pairs(self.in_flight) do
    labels[label] = true
  end
  return labels
end

function BrokerClient:broadcast_craft(label, amount, kind)
  if self:label_in_flight(label) then
    return nil
  end

  local job_id = self:_next_job_id(label)
  local payload = Protocol.craft_req(job_id, label, amount, kind)

  for _, broker in ipairs(self.brokers) do
    if self.modem and broker.address then
      self.modem.send(broker.address, self.modem_port, payload)
    end
  end

  self.in_flight[label] = job_id
  local now = self.computer and self.computer.uptime and self.computer.uptime() or 0
  self.jobs[job_id] = {
    label = label,
    amount = amount,
    kind = kind,
    state = "pending_ack",
    started_at = now,
  }
  self.log(string.format("[Coordinator] craft_req %s %s x%d", job_id, label, amount))
  return job_id
end

function BrokerClient:ping_all(coordinator_id)
  local payload = Protocol.ping(coordinator_id or "coordinator")
  for _, broker in ipairs(self.brokers) do
    if self.modem and broker.address then
      self.modem.send(broker.address, self.modem_port, payload)
    end
  end
end

function BrokerClient:handle_message(_receiver, sender, port, _, payload)
  if port ~= self.modem_port then
    return nil
  end

  local decoded = Protocol.decode(payload)
  if not decoded then
    return nil
  end

  if decoded.type == "craft_ack" then
    local ack = Protocol.parse_craft_ack(decoded.fields)
    if not ack then return nil end
    local job = self.jobs[ack.job_id]
    if not job or job.state ~= "pending_ack" then
      return nil
    end
    job.state = "running"
    job.broker_id = ack.broker_id
    job.machine_id = ack.machine_id
    job.broker_addr = sender
    self.log(string.format("[Coordinator] craft_ack %s -> %s@%s",
      ack.job_id, ack.machine_id, ack.broker_id))
    return { event = "ack", job = job, ack = ack }
  end

  if decoded.type == "craft_done" then
    local done = Protocol.parse_craft_done(decoded.fields)
    if not done then return nil end
    local job = self.jobs[done.job_id]
    if job then
      self.in_flight[job.label] = nil
      self.jobs[done.job_id] = nil
      self.log(string.format("[Coordinator] craft_done %s", done.job_id))
      return { event = "done", job = job, done = done }
    end
    return nil
  end

  if decoded.type == "craft_fail" then
    local fail = Protocol.parse_craft_fail(decoded.fields)
    if not fail then return nil end
    local job = self.jobs[fail.job_id]
    -- Ignore fail while waiting for another broker to ack (broadcast semantics).
    if job and job.state == "running" then
      self.log(string.format("[Coordinator] craft_fail ignored (running) %s: %s",
        fail.job_id, fail.reason))
    elseif job and job.state == "pending_ack" then
      self.log(string.format("[Coordinator] craft_fail %s: %s (awaiting ack or timeout)",
        fail.job_id, fail.reason))
      return { event = "fail", job = job, fail = fail }
    end
    return nil
  end

  if decoded.type == "pong" then
    return { event = "pong", broker_id = decoded.fields[2] }
  end

  if Protocol.is_reserved(decoded.type) then
    if decoded.type == "capability_advertise" then
      local adv = Protocol.parse_capability_advertise(decoded.fields)
      return { event = "capability_advertise", advertise = adv }
    end
  end

  return nil
end

-- Clear jobs with no ack after timeout (all brokers silent / no capability).
function BrokerClient:expire_pending(timeouts)
  timeouts = timeouts or 30
  local now = self.computer and self.computer.uptime and self.computer.uptime() or 0
  local expired = {}

  for job_id, job in pairs(self.jobs) do
    if job.state == "pending_ack" and (now - (job.started_at or 0)) >= timeouts then
      self.in_flight[job.label] = nil
      self.jobs[job_id] = nil
      expired[#expired + 1] = job
      self.log(string.format("[Coordinator] craft timeout %s (%s)", job_id, job.label))
    end
  end

  return expired
end

return BrokerClient
