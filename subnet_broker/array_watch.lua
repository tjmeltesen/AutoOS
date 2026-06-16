--[[
  AutoOS — Array Watch loop (broker)

  AE2 handles bulk input delivery. This loop only:
    * monitors lane health
    * force-disables work on maintenance fault
    * recovers circuits from item input buses when processing completes
    * reports lane status to orchestrator
]]

local Protocols = require("network_protocols")
local CircuitLoop = require("circuit_loop")

local ArrayWatch = {}
ArrayWatch.__index = ArrayWatch

local HEARTBEAT_S = 10

function ArrayWatch.new(deps)
  deps = deps or {}
  local self = setmetatable({}, ArrayWatch)
  self.config = deps.config or error("ArrayWatch.new: config required")
  self.poll = deps.poll or error("ArrayWatch.new: poll required")
  self.circuit_manager = deps.circuit_manager
  self.link = deps.link
  self.log = deps.log or function() end
  self.now = deps.now or function() return 0 end
  self.reply_to = deps.reply_to
  self.lane_state = {}
  self._last_heartbeat = 0
  self._fast_tick = false
  self.circuit_loop = deps.circuit_loop
  if not self.circuit_loop then
    self.circuit_loop = CircuitLoop.new({
      config = self.config,
      component = deps.component or error("ArrayWatch.new: component required when circuit_loop not injected"),
      circuit_manager = self.circuit_manager or error("ArrayWatch.new: circuit_manager required"),
      log = self.log,
      now = self.now,
    })
  end
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
  if self.circuit_loop and self.circuit_loop.reset_lane then
    self.circuit_loop:reset_lane(machine_id)
  end
  self.lane_state[machine_id] = lane
end

function ArrayWatch:_run_circuit_loop(machine, st)
  local machine_id = machine.id
  local lane = self.lane_state[machine_id] or {}
  local wants_fast, events = self.circuit_loop:tick_lane(machine, st)
  if wants_fast then self._fast_tick = true end

  for _, ev in ipairs(events or {}) do
    if ev.type == "staged" then
      if lane.last_state ~= "running" then
        self:_send_health(machine_id, "running", "circuit staged to bus")
      end
      lane.last_state = "running"
    elseif ev.type == "recover_ok" then
      self:_send_event(Protocols.EVENT.CIRCUIT_RECOVERED, machine_id, ev.detail or "ok")
      self:_send_health(machine_id, "circuit_recovered", "circuit returned to buffer")
      lane.last_state = "idle"
      self.log("[ArrayWatch] " .. machine_id .. " recover ok: " .. tostring(ev.detail))
    elseif ev.type == "recover_failed" then
      self:_send_event(Protocols.EVENT.CIRCUIT_RECOVER_FAILED, machine_id, tostring(ev.detail))
      self:_send_health(machine_id, "fault", "recover failed: " .. tostring(ev.detail))
      lane.last_state = "fault"
      self.log("[ArrayWatch] " .. machine_id .. " recover failed: " .. tostring(ev.detail))
    end
  end

  if lane.last_state ~= "fault" then
    local dbg = self.circuit_loop:get_lane_debug(machine_id)
    local running = dbg and dbg.state ~= "idle"
    local state = running and "running" or "idle"
    if lane.last_state ~= state then
      self:_send_health(machine_id, state, running and "circuit loop active" or "idle")
    end
    lane.last_state = state
  end

  self.lane_state[machine_id] = lane
end

function ArrayWatch:any_fast_tick()
  return self._fast_tick or (self.circuit_loop and self.circuit_loop:any_fast_tick()) or false
end

function ArrayWatch:tick()
  self._fast_tick = false
  local results = self.poll:poll_all()
  for _, machine in ipairs(self.config.machines) do
    local st = results[machine.id] or { available = false, healthy = false }
    if not st.available then
      self:_send_health(machine.id, "fault", "gt_machine proxy unavailable")
      self.lane_state[machine.id] = { was_processing = false, last_state = "fault" }
    elseif st.maintenance_fault then
      self:_handle_fault(machine.id, st)
    else
      self:_run_circuit_loop(machine, st)
    end
  end

  local now = self.now()
  if now - self._last_heartbeat >= HEARTBEAT_S then
    self._last_heartbeat = now
    self:_send_health("all", "healthy", "heartbeat")
  end
end

return ArrayWatch
