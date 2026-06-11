--[[
  Universal Craft Brokers — broker main loop.
]]

local Protocol = require("shared.protocol")
local Dispatcher = require("broker.dispatcher")
local Registry = require("broker.registry")
local Adapter = require("broker.adapter")
local Executor = require("broker.executor")
local RecipeRegistry = require("shared.recipe_registry")

local Broker = {}
Broker.__index = Broker

function Broker.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Broker)
  self.deps = deps
  self.registry = Registry.new(deps.config, deps.component)
  self.adapter = Adapter.new(self.registry)
  self.executor = Executor.new({
    registry = self.registry,
    me = deps.me,
    computer = deps.computer,
    grace_seconds = deps.grace_seconds,
  })
  self.modem = deps.modem
  self.modem_port = deps.modem_port or 4410
  self.coordinator_addr = deps.coordinator_addr
  self.broker_id = deps.config and deps.config.broker_id or "broker"
  self.cache = { machines = {} }
  self.accepted_jobs = {}
  self.log = deps.log or function() end
  return self
end

function Broker:open_modem()
  if self.modem and self.modem.open then
    self.modem.open(self.modem_port)
  end
end

function Broker:send_to_coordinator(payload)
  if self.modem and self.coordinator_addr then
    self.modem.send(self.coordinator_addr, self.modem_port, payload)
  end
end

function Broker:handle_message(_receiver, sender, port, _, payload)
  if port ~= self.modem_port then
    return
  end
  if self.coordinator_addr and sender ~= self.coordinator_addr then
    return
  end
  if not self.coordinator_addr then
    self.coordinator_addr = sender
  end

  local decoded = Protocol.decode(payload)
  if not decoded then
    return
  end

  if decoded.type == "ping" then
    self:send_to_coordinator(Protocol.pong(self.broker_id))
    return
  end

  if decoded.type == "craft_req" then
    self:_handle_craft_req(decoded.fields)
    return
  end

  if Protocol.is_reserved(decoded.type) then
  end
end

function Broker:_handle_craft_req(fields)
  self.adapter:poll(self.cache)

  local req = Protocol.parse_craft_req(fields)
  if not req or req.amount <= 0 then
    return
  end

  if self.accepted_jobs[req.job_id] or self.executor:busy() then
    return
  end

  if not RecipeRegistry.known(req.label) then
    self:send_to_coordinator(Protocol.craft_fail(req.job_id, "unknown_recipe"))
    return
  end

  local machine_id, reason = Dispatcher.pick(
    req.label, self.registry:list(), self.cache)

  if not machine_id then
    if reason == "unknown_recipe" then
      self:send_to_coordinator(Protocol.craft_fail(req.job_id, reason))
    end
    return
  end

  local ok, err = self.executor:start(req.job_id, machine_id, req.label, req.amount)
  if not ok then
    self:send_to_coordinator(Protocol.craft_fail(req.job_id, err or "start_failed"))
    return
  end

  self.accepted_jobs[req.job_id] = true
  self:send_to_coordinator(Protocol.craft_ack(req.job_id, machine_id, self.broker_id))
  self.log(string.format("[Broker] ack %s -> %s (%s x%d)",
    req.job_id, machine_id, req.label, req.amount))
end

function Broker:tick()
  self.adapter:poll(self.cache)
  local result = self.executor:tick(self.cache)
  if not result then
    return nil
  end

  if result.event == "done" then
    self:send_to_coordinator(Protocol.craft_done(result.job_id, result.machine_id))
    self.accepted_jobs[result.job_id] = nil
    self.log(string.format("[Broker] done %s on %s", result.job_id, result.machine_id))
    return result
  end

  if result.event == "fail" then
    self:send_to_coordinator(Protocol.craft_fail(result.job_id, result.reason))
    self.accepted_jobs[result.job_id] = nil
    self.log(string.format("[Broker] fail %s: %s", result.job_id, result.reason))
    return result
  end

  return result
end

function Broker:run_step(event_name, ...)
  if event_name == "modem_message" then
    self:handle_message(...)
  end
  return self:tick()
end

return Broker
