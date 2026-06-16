--[[
  AutoOS — Array Watch loop (broker)

  AE2 handles bulk input delivery. This loop only:
    * monitors lane health
    * force-disables work on maintenance fault
    * recovers circuits from item input buses when processing completes
    * reports lane status to orchestrator
]]

local Protocols = require("network_protocols")

local ArrayWatch = {}
ArrayWatch.__index = ArrayWatch

local HEARTBEAT_S = 10

function ArrayWatch.new(deps)
  deps = deps or {}
  local self = setmetatable({}, ArrayWatch)
  self.config = deps.config or error("ArrayWatch.new: config required")
  self.poll = deps.poll or error("ArrayWatch.new: poll required")
  self.circuit_manager = deps.circuit_manager or error("ArrayWatch.new: circuit_manager required")
  self.link = deps.link
  self.log = deps.log or function() end
  self.now = deps.now or function() return 0 end
  self.reply_to = deps.reply_to
  self.lane_state = {}
  self._last_heartbeat = 0
  return self
end

function ArrayWatch:_send_health(machine_id, state, detail)
  if not self.link or not self.reply_to or self.reply_to == "" then return end
  self.link:send(self.reply_to, Protocols.broker_health(
    self.config.subnet_id, machine_id, state, detail or ""
  ))
end

function ArrayWatch:_send_event(event, machine_id, detail)
  if not self.link or not self.reply_to or self.reply_to == "" then return end
  self.link:send(self.reply_to, Protocols.broker_event(
    self.config.subnet_id, event, machine_id, 0, detail or ""
  ))
end

local function machine_processing(st)
  return st and st.available and st.active
end

function ArrayWatch:_handle_fault(machine_id, st)
  local lane = self.lane_state[machine_id] or {}
  if lane.last_state ~= "fault" then
    local proxy = self.poll:get_proxy(machine_id)
    if proxy and proxy.setWorkAllowed then
      local ok, err = pcall(proxy.setWorkAllowed, false)
      if not ok then
        self.log(string.format("[ArrayWatch] %s setWorkAllowed(false) failed: %s", machine_id, tostring(err)))
      end
    end
    self:_send_health(machine_id, "fault", st.fault_message or "maintenance fault")
    self:_send_event(Protocols.EVENT.MACHINE_FAULT, machine_id, st.fault_message or "")
    self.log(string.format("[ArrayWatch] %s FAULT: %s", machine_id, tostring(st.fault_message)))
  end
  lane.last_state = "fault"
  lane.was_processing = machine_processing(st)
  self.lane_state[machine_id] = lane
end

function ArrayWatch:_recover_if_processing_done(machine_id, st)
  local lane = self.lane_state[machine_id] or { was_processing = false }
  local processing = machine_processing(st)
  local recovered = false

  if lane.was_processing and not processing then
    local ok, err = self.circuit_manager:recover_circuit(machine_id, nil)
    if ok then
      recovered = true
      self:_send_event(Protocols.EVENT.CIRCUIT_RECOVERED, machine_id, "ok")
      self:_send_health(machine_id, "circuit_recovered", "circuit returned to ME")
      self.log("[ArrayWatch] " .. machine_id .. " recovered circuit after processing complete")
    else
      self:_send_event(Protocols.EVENT.CIRCUIT_RECOVER_FAILED, machine_id, tostring(err))
      self:_send_health(machine_id, "fault", "recover failed: " .. tostring(err))
      self.log("[ArrayWatch] " .. machine_id .. " recover failed: " .. tostring(err))
    end
  end

  if not recovered then
    local state = processing and "running" or "idle"
    if lane.last_state ~= state then
      self:_send_health(machine_id, state, state == "running" and "active" or "idle")
    end
    lane.last_state = state
  end

  lane.was_processing = processing
  self.lane_state[machine_id] = lane
end

function ArrayWatch:tick()
  local results = self.poll:poll_all()
  for _, machine in ipairs(self.config.machines) do
    local st = results[machine.id] or { available = false, healthy = false }
    if not st.available then
      self:_send_health(machine.id, "fault", "gt_machine proxy unavailable")
      self.lane_state[machine.id] = { was_processing = false, last_state = "fault" }
    elseif st.maintenance_fault then
      self:_handle_fault(machine.id, st)
    else
      self:_recover_if_processing_done(machine.id, st)
    end
  end

  local now = self.now()
  if now - self._last_heartbeat >= HEARTBEAT_S then
    self._last_heartbeat = now
    self:_send_health("all", "healthy", "heartbeat")
  end
end

return ArrayWatch
