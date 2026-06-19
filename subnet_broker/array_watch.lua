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
  self.pending_jobs = deps.pending_jobs or {}
  self._scheduler_rr = 1
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
      pending_jobs = self.pending_jobs,
      log = self.log,
      now = self.now,
    })
  end
  if self.central_dispatch and self.central_dispatch.pending_queue then
    self.pending_jobs = self.central_dispatch:pending_queue()
  end
  if self.config.input_mode == "central"
    and self.central_dispatch
    and (self.config.scheduler == nil or (self.config.scheduler.persist_jobs or "startup_sweep") == "startup_sweep") then
    self.central_dispatch:startup_sweep()
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

function ArrayWatch:_max_parallel_lanes()
  local sched = self.config.scheduler or {}
  return sched.max_parallel_lanes or #(self.config.machines or {})
end

function ArrayWatch:_max_job_attempts()
  local sched = self.config.scheduler or {}
  return sched.max_job_attempts or 2
end

function ArrayWatch:_active_job_count()
  local n = 0
  for _, job in ipairs(self.pending_jobs or {}) do
    if job.status == "running" then n = n + 1 end
  end
  return n
end

function ArrayWatch:_lane_schedulable(machine, st)
  if not st or not st.available or not st.healthy then return false, "unhealthy" end
  if self.lane_dispatch.is_lane_faulted and self.lane_dispatch:is_lane_faulted(machine.id) then
    return false, "faulted"
  end
  if self.lane_dispatch:is_lane_busy(machine.id) then return false, "busy" end
  if st.active or st.has_work then return false, "machine busy" end
  return true
end

function ArrayWatch:_machine_order()
  local machines = self.config.machines or {}
  local n = #machines
  local out = {}
  if n == 0 then return out end
  local start = self._scheduler_rr
  for i = 0, n - 1 do
    out[#out + 1] = machines[((start - 1 + i) % n) + 1]
  end
  return out
end

function ArrayWatch:_advance_scheduler_rr(machine)
  local machines = self.config.machines or {}
  for i, m in ipairs(machines) do
    if m == machine or m.id == machine.id then
      self._scheduler_rr = (i % #machines) + 1
      return
    end
  end
end

function ArrayWatch:_remove_job(job)
  for i = #self.pending_jobs, 1, -1 do
    if self.pending_jobs[i] == job then
      table.remove(self.pending_jobs, i)
      return
    end
  end
end

function ArrayWatch:_harvest_finished_jobs()
  if not self.lane_dispatch or not self.lane_dispatch.consume_finished_job then return end
  for _, machine in ipairs(self.config.machines or {}) do
    local job = self.lane_dispatch:consume_finished_job(machine.id)
    if job then
      if job.status == "done" then
        self:_remove_job(job)
        self.log(string.format("[ArrayWatch] job %s complete on %s", tostring(job.id), machine.id))
      elseif job.status == "failed" then
        if (job.attempt or 1) < self:_max_job_attempts() then
          job.attempt = (job.attempt or 1) + 1
          job.status = "pending"
          job.machine_id = nil
          self.log(string.format("[ArrayWatch] job %s requeued attempt %d", tostring(job.id), job.attempt))
        else
          job.status = "dead"
          self.log(string.format("[ArrayWatch] job %s dead after %d attempts: %s",
            tostring(job.id), job.attempt or 1, tostring(job.last_error)))
        end
      end
    end
  end
end

function ArrayWatch:step_watchdog()
  if not self.lane_dispatch or not self.lane_dispatch.get_lane_debug then return end
  local sched = self.config.scheduler or {}
  local grace = sched.watchdog_grace_s or 10
  local now = self.now()
  for _, machine in ipairs(self.config.machines or {}) do
    local dbg = self.lane_dispatch:get_lane_debug(machine.id)
    if dbg and dbg.state ~= "idle" and dbg.state ~= "faulted" and type(dbg.deadline) == "number" then
      if now > dbg.deadline + grace then
        local detail = string.format("watchdog timeout in %s", tostring(dbg.state))
        if self.lane_dispatch.watchdog_fault and self.lane_dispatch:watchdog_fault(machine.id, detail) then
          self:_send_event(Protocols.EVENT.CIRCUIT_RECOVER_FAILED, machine.id, detail)
          self:_send_health(machine.id, "fault", detail)
          self.log(string.format("[ArrayWatch] %s %s", machine.id, detail))
        end
      end
    end
  end
end

function ArrayWatch:step_scheduler(poll_results)
  if self.config.input_mode ~= "central" then return {} end
  poll_results = poll_results or {}
  local assigned = {}
  self:step_watchdog()
  self:_harvest_finished_jobs()
  local budget = self:_max_parallel_lanes() - self:_active_job_count()
  if budget <= 0 then return assigned end
  for _, job in ipairs(self.pending_jobs or {}) do
    if budget <= 0 then break end
    if job.status == "pending" then
      for _, machine in ipairs(self:_machine_order()) do
        local ok_lane = self:_lane_schedulable(machine, poll_results[machine.id])
        if ok_lane then
          local ok_assign, reason = self.lane_dispatch:assign_job(machine, job)
          if ok_assign then
            budget = budget - 1
            self:_advance_scheduler_rr(machine)
            assigned[#assigned + 1] = machine.id
            local lane = self.lane_state[machine.id] or {}
            lane.last_state = "running"
            self.lane_state[machine.id] = lane
            self:_send_health(machine.id, "running", "job " .. tostring(job.id))
            self.log(string.format("[ArrayWatch] dispatched job %s -> %s", tostring(job.id), machine.id))
            break
          else
            job.last_blocked_reason = reason
          end
        end
      end
    end
  end
  return assigned
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

function ArrayWatch:handle_poll_result(machine, st)
  local is_central = self.config.input_mode == "central"
  if not st or not st.available then
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

function ArrayWatch:step_central(poll_results)
  if self.config.input_mode ~= "central" or not self.central_dispatch then return end
  local cev = self.central_dispatch:tick(poll_results or {}, self.lane_dispatch)
  if self.central_dispatch:any_fast_tick() then self._fast_tick = true end
  self:_handle_central_events(cev)
end

function ArrayWatch:step_lane(machine, poll_results)
  poll_results = poll_results or {}
  local st = poll_results[machine.id] or { available = false, healthy = false }
  self:handle_poll_result(machine, st)
end

function ArrayWatch:step_heartbeat()
  local now = self.now()
  if now - self._last_heartbeat >= HEARTBEAT_S then
    self._last_heartbeat = now
    self:_send_health("all", "healthy", "heartbeat")
  end
end

function ArrayWatch:tick()
  self._fast_tick = false
  local results = self.poll:poll_all()
  local is_central = self.config.input_mode == "central"

  if is_central and self.central_dispatch then
    self:step_central(results)
    self:step_scheduler(results)
  end

  local order = self.lane_dispatch:lane_order(self.config.machines)
  for _, machine in ipairs(order) do
    self:step_lane(machine, results)
  end

  if not is_central then
    self.lane_dispatch:advance_round_robin(self.config.machines)
  end

  self:step_heartbeat()
end

return ArrayWatch
