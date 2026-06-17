--[[
  AutoOS — Array Watch loop (broker)

  Polls lane health, runs central or per-lane dispatch, reports telemetry.
]]

local Protocols = require("network_protocols")
local LaneDispatch = require("lane_dispatch")
local CentralDispatch = require("central_dispatch")

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
  self.lane_dispatch = deps.lane_dispatch
  if not self.lane_dispatch then
    self.lane_dispatch = LaneDispatch.new({
      config = self.config,
      component = deps.component or error("ArrayWatch.new: component required when lane_dispatch not injected"),
      circuit_manager = self.circuit_manager or error("ArrayWatch.new: circuit_manager required"),
      log = self.log,
      now = self.now,
    })
  end
  self.central_dispatch = deps.central_dispatch
  if self.config.input_mode == "central" and not self.central_dispatch then
    self.central_dispatch = CentralDispatch.new({
      config = self.config,
      component = deps.component or error("ArrayWatch.new: component required for central_dispatch"),
      circuit_manager = self.circuit_manager or error("ArrayWatch.new: circuit_manager required"),
      lane_dispatch = self.lane_dispatch,
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
  if self.lane_dispatch and self.lane_dispatch.reset_lane then
    self.lane_dispatch:reset_lane(machine_id)
  end
  self.lane_state[machine_id] = lane
end

function ArrayWatch:_run_lane_dispatch(machine, st)
  local machine_id = machine.id
  local lane = self.lane_state[machine_id] or {}
  local wants_fast, events = self.lane_dispatch:tick_lane(machine, st)
  if wants_fast then self._fast_tick = true end

  for _, ev in ipairs(events or {}) do
    if ev.type == "staged" or ev.type == "buffer_ready" then
      if lane.last_state ~= "running" then
        self:_send_health(machine_id, "running", ev.detail or "lane active")
      end
      lane.last_state = "running"
    elseif ev.type == "recover_ok" then
      self:_send_event(Protocols.EVENT.CIRCUIT_RECOVERED, machine_id, ev.detail or "ok")
      self:_send_health(machine_id, "circuit_recovered", "circuit returned")
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
    local dbg = self.lane_dispatch:get_lane_debug(machine_id)
    local running = dbg and dbg.state ~= "idle"
    local state = running and "running" or "idle"
    if lane.last_state ~= state and state == "idle" and not (events and events[#events] and events[#events].type == "recover_ok") then
      self:_send_health(machine_id, state, "idle")
    elseif lane.last_state ~= state and state == "running" then
      self:_send_health(machine_id, state, "lane dispatch active")
    end
    if dbg and dbg.state ~= "idle" then
      lane.last_state = "running"
    elseif lane.last_state ~= "circuit_recovered" then
      lane.last_state = state
    end
  end

  self.lane_state[machine_id] = lane
end

function ArrayWatch:_handle_central_events(events)
  for _, ev in ipairs(events or {}) do
    if ev.type == "central_staged" and ev.machine_id then
      local lane = self.lane_state[ev.machine_id] or {}
      self:_send_health(ev.machine_id, "running", ev.detail or "central batch assigned")
      lane.last_state = "running"
      self.lane_state[ev.machine_id] = lane
    end
  end
end

function ArrayWatch:any_fast_tick()
  if self._fast_tick then return true end
  if self.central_dispatch and self.central_dispatch:any_fast_tick() then return true end
  return self.lane_dispatch and self.lane_dispatch:any_fast_tick() or false
end

function ArrayWatch:tick()
  self._fast_tick = false
  local results = self.poll:poll_all()
  local is_central = self.config.input_mode == "central"

  if is_central and self.central_dispatch then
    local cev = self.central_dispatch:tick(results, self.lane_dispatch)
    if self.central_dispatch:any_fast_tick() then self._fast_tick = true end
    self:_handle_central_events(cev)
  end

  local order = self.lane_dispatch:lane_order(self.config.machines)
  for _, machine in ipairs(order) do
    local st = results[machine.id] or { available = false, healthy = false }
    if not st.available then
      self:_send_health(machine.id, "fault", "gt_machine proxy unavailable")
      self.lane_state[machine.id] = { last_state = "fault" }
      if self.lane_dispatch.reset_lane then
        self.lane_dispatch:reset_lane(machine.id)
      end
    elseif st.maintenance_fault then
      self:_handle_fault(machine.id, st)
    else
      if is_central then
        local dbg = self.lane_dispatch:get_lane_debug(machine.id)
        if dbg and dbg.state ~= "idle" then
          self:_run_lane_dispatch(machine, st)
        end
      else
        self:_run_lane_dispatch(machine, st)
      end
    end
  end

  if not is_central then
    self.lane_dispatch:advance_round_robin(self.config.machines)
  end

  local now = self.now()
  if now - self._last_heartbeat >= HEARTBEAT_S then
    self._last_heartbeat = now
    self:_send_health("all", "healthy", "heartbeat")
  end
end

return ArrayWatch
