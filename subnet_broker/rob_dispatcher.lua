--[[
  AutoOS — ROB Dispatcher (Reorder Buffer / Atomic Dispatcher)
  Phase 3: Central buffer monitor + job creation + lane assignment + mutex management.
  All 5 tick phases inlined — no rob_tick.lua dependency.
]]

local FluidTanks = require("fluid_tanks")
local C = require("rob_core.constants")
local LockManager = require("rob_core.lock_manager")
local LaneState = require("rob_core.lane_state")
local BufferMonitor = require("rob_services.buffer_monitor")
local MachineSelector = require("rob_services.machine_selector")
local CompletionDetector = require("rob_services.completion_detector")
local JobReaper = require("rob_services.job_reaper")
local Watchdog = require("rob_services.watchdog")
local JobAssigner = require("rob_services.job_assigner")
local AdmissionControl = require("rob_services.admission_control")
local JobManifest = require("rob_core.job_manifest")
local JobFactory = require("rob_services.job_factory")

local ROBDispatcher = {}
ROBDispatcher.__index = ROBDispatcher

---------------------------------------------------------------------------
-- Constructor
---------------------------------------------------------------------------

function ROBDispatcher.new(registry, config, deps)
  deps = deps or {}

  local self = setmetatable({}, ROBDispatcher)
  self._registry = registry or error("ROBDispatcher.new: registry required")
  self._config = config or {}
  self._now = deps.now or function() return 0 end
  self._log = deps.log or function() end
  self._circuit_manager = deps.circuit_manager

  self._max_parallel_lanes = deps.max_parallel_lanes
    or (config.scheduler and config.scheduler.max_parallel_lanes) or nil
  self._max_job_attempts = deps.max_job_attempts
    or (config.scheduler and config.scheduler.max_job_attempts) or 2
  self._watchdog_grace_s = deps.watchdog_grace_s
    or (config.scheduler and config.scheduler.watchdog_grace_s) or 10

  self._buf_mon = BufferMonitor.new()
  self._lock_mgr = LockManager.new()
  self._machine_sel = MachineSelector.new(self._max_parallel_lanes)
  self._pending_jobs = {}
  self._job_seq = 0
  self._job_seq_ref = { 0 }
  self._lanes = {}
  self._results = {}
  self._yield_fn = nil

  local s = self
  self._safe_yield = function()
    if s._yield_fn then s._yield_fn() end
  end

  self._fluid_tanks = FluidTanks

  -- Lane wake callback (set by caller after construction)
  self._wake_lane = nil

  -- Fault capture callback (set by caller after construction)
  self._fault = nil

  self._log(string.format("[ROB] NEW dispatcher instance %s", tostring(self):sub(8)))
  return self
end

---------------------------------------------------------------------------
-- tick()
---------------------------------------------------------------------------

function ROBDispatcher:tick(poll_results, yield_fn)
  poll_results = poll_results or {}
  self._tick_n = (self._tick_n or 0) + 1
  local prev_yield = self._yield_fn
  self._yield_fn = yield_fn
  local now = self._now()

  -- Phase 1: Completion detection
  CompletionDetector.poll(self._results, self._lanes, self._pending_jobs,
    function(mid, lane) self._lock_mgr:release(mid, lane) end, self._log)

  -- Phase 2: Job reaping
  local pre_reap = #self._pending_jobs
  JobReaper.reap(self._pending_jobs, self._max_job_attempts)
  if #self._pending_jobs ~= pre_reap then
    self._log(string.format("[ROB] reap: %d -> %d pending", pre_reap, #self._pending_jobs))
  end

  -- Phase 3: Watchdog
  Watchdog.check(self._lanes, self._pending_jobs, now, self._watchdog_grace_s,
    function(mid, lane) self._lock_mgr:release(mid, lane) end, self._log)

  -- Phase 4: Buffer monitor
  local job_stabilize = AdmissionControl.job_stabilize_s(self._config)
  local buf_state_before = self._buf_mon._state
  local buf_result = BufferMonitor.step(
    self._buf_mon, now, self._registry, self._config,
    {
      build_manifest = function()
        local ok, m = pcall(JobManifest.build, self._registry, self._config,
          self._fluid_tanks, self._safe_yield)
        if not ok then
          if self._fault then self._fault("rob.build_manifest", tostring(m)) end
          return nil
        end
        return m
      end,
      enqueue_job = function(manifest)
        local job, err = JobFactory.enqueue(manifest, "central", self._registry, self._config,
          self._log, self._now, self._pending_jobs, self._job_seq_ref, self._safe_yield)
        if not job and self._fault then
          self._fault("rob.enqueue_job", err or "enqueue returned nil")
        end
        return job, err
      end,
      check_admission = function()
        local pcall_ok, result = pcall(AdmissionControl.is_ok, self._registry, self._config,
          self._circuit_manager, self._lanes, self._log, self._safe_yield, C)
        if not pcall_ok then
          if self._fault then self._fault("rob.check_admission", tostring(result)) end
	        return false
        end
        return result  -- ponytail: was returning pcall_ok (always true), now returns actual is_ok result
      end,
      log = self._log,
      fault = self._fault,
    },
    self._pending_jobs, self._safe_yield, job_stabilize
  )
  local events = buf_result.events or {}
  if self._buf_mon._state ~= buf_state_before then
    self._log(string.format("[ROB] buf: %s -> %s", buf_state_before, self._buf_mon._state))
  end
  -- Heartbeat when stuck in STABILIZING: log elapsed every 10 ticks
  if self._buf_mon._state == C.DIS_STABILIZING and self._tick_n % 10 == 1 then
    local elapsed = now - self._buf_mon._stable_since
    local fp_slots = 0; for _ in pairs(self._buf_mon._fingerprint or {}) do fp_slots = fp_slots + 1 end
    self._log(string.format("[ROB] buf: stabilizing for %.1fs (need %.1fs) fp_slots=%d",
      elapsed, job_stabilize, fp_slots))
  end
  for _, ev in ipairs(events) do
    self._log(string.format("[ROB] buf event: %s %s", ev.type, tostring(ev.detail or ev.job_id or "")))
  end

  -- Phase 5: Job assignment
  local pending_count = 0
  for _, job in ipairs(self._pending_jobs) do
    if job.status == "pending" then pending_count = pending_count + 1 end
  end
  local assign_result = JobAssigner.assign(
    self._pending_jobs, poll_results,
    self._machine_sel, self._lock_mgr, self._lanes,
    self._config, self._config.shared_interface_address,
    self._now, self._log, self._safe_yield
  )
  local jobs_assigned = assign_result.jobs_assigned or {}
  if pending_count > 0 and #jobs_assigned == 0 then
    local locks = 0
    for _ in pairs(self._lock_mgr._locks) do locks = locks + 1 end
    self._log(string.format("[ROB] assign: %d pending, 0 assigned -- budget=%d rr=%d locks=%d",
      pending_count, self._machine_sel:available_budget(self._lanes),
      self._machine_sel._rr_index, locks))
  end
  -- Merge assigner events and log what we're returning in jobs_assigned
  for _, ev in ipairs(assign_result.events or {}) do
    events[#events + 1] = ev
  end
  for _, mid in ipairs(jobs_assigned) do
    self._log(string.format("[ROB] staged: job -> %s", tostring(mid)))
  end
  -- Wake assigned lanes directly so we don't depend on task_central_dispatch
  if self._wake_lane then
    for _, mid in ipairs(jobs_assigned) do
      self._wake_lane(mid)
    end
  end
  self._log(string.format("[ROB] tick done: events=%d assigned=%d",
    #events, #jobs_assigned))

  self._yield_fn = prev_yield
  self._job_seq = self._job_seq_ref[1]

  -- Periodic state dump every ~30 ticks
  if self._tick_n % 30 == 1 then
    local working, faults, locks = 0, 0, 0
    for _, l in pairs(self._lanes) do
      if LaneState.is_working(l) then working = working + 1 end
      if LaneState.is_faulted(l) then faults = faults + 1 end
    end
    for _ in pairs(self._lock_mgr._locks) do locks = locks + 1 end
    self._log(string.format(
      "[ROB] tick=%d buf=%s pending=%d working=%d faulted=%d locks=%d batch=%s seq=%d ran=%s",
      self._tick_n, self._buf_mon._state, #self._pending_jobs, working, faults, locks,
      tostring(self._buf_mon._batch_claimed), self._job_seq_ref[1],
      self._lane_ran and (function() local r={}; for k,v in pairs(self._lane_ran) do r[#r+1]=k.."="..tostring(v) end; return table.concat(r,",") end)() or "nil"))
  end

  return { events = events, jobs_assigned = jobs_assigned }
end

---------------------------------------------------------------------------
-- Public API — results
---------------------------------------------------------------------------

function ROBDispatcher:get_results_table()
  return self._results
end

---------------------------------------------------------------------------
-- Public API — lane fault / recovery
---------------------------------------------------------------------------

function ROBDispatcher:fault_lane(machine_id, reason)
  local lane = self._lanes[machine_id]
  if lane == nil then
    lane = LaneState.create(machine_id, self._now)
    self._lanes[machine_id] = lane
  end
  LaneState.fault(lane, reason)
  self._lock_mgr:release(machine_id, lane)
  self._log(string.format("[ROBDispatcher] %s FAULTED: %s", machine_id, reason))
end

function ROBDispatcher:recover_lane(machine_id)
  local lane = self._lanes[machine_id]
  if lane ~= nil and LaneState.is_faulted(lane) then
    LaneState.recover(lane)
    self._lock_mgr:release(machine_id, lane)
    self._log(string.format("[ROBDispatcher] %s RECOVERED", machine_id))
  end
end

---------------------------------------------------------------------------
-- Public API — transport locks
---------------------------------------------------------------------------

function ROBDispatcher:release_transport_locks(machine_id)
  local lane = self._lanes[machine_id]
  self._lock_mgr:release_transport(machine_id, lane, self._log)
end

---------------------------------------------------------------------------
-- Public API — lock management
---------------------------------------------------------------------------

function ROBDispatcher:get_locks()
  return self._lock_mgr:get_locks()
end

function ROBDispatcher:release_all_locks()
  self._lock_mgr:release_all(self._lanes)
end

---------------------------------------------------------------------------
-- Public API — introspection
---------------------------------------------------------------------------

function ROBDispatcher:any_fast_tick()
  if self._buf_mon._state ~= C.DIS_IDLE then return true end
  for _, lane in pairs(self._lanes) do
    if LaneState.is_working(lane) then return true end
  end
  for _, job in ipairs(self._pending_jobs) do
    if job.status == "pending" then return true end
  end
  return false
end

function ROBDispatcher:pending_count()
  return #self._pending_jobs
end

function ROBDispatcher:pending_queue()
  return self._pending_jobs
end

function ROBDispatcher:get_assigned_job(machine_id)
  local lane = self._lanes[machine_id]
  if lane == nil then
    -- No lane record at all — assignment was never made or lane was wiped
    self._log(string.format("[ROB] get_assigned_job(%s): nil — no lane record", tostring(machine_id)))
    return nil
  end
  if not LaneState.is_working(lane) then
    self._log(string.format("[ROB] get_assigned_job(%s): nil — lane state=%s (not WORKING)",
      tostring(machine_id), tostring(lane.state)))
    return nil
  end
  for _, job in ipairs(self._pending_jobs) do
    if job.id == lane.current_job_id then return job end
  end
  -- Lane is WORKING but no matching job in pending queue — desync
  local pending_ids = {}
  for _, job in ipairs(self._pending_jobs) do
    pending_ids[#pending_ids + 1] = tostring(job.id) .. "(" .. tostring(job.status) .. ")"
  end
  self._log(string.format("[ROB] get_assigned_job(%s): nil — lane WORKING current_job_id=%s not found in pending_jobs=%s",
    tostring(machine_id), tostring(lane.current_job_id),
    #pending_ids > 0 and table.concat(pending_ids, ",") or "(empty)"))
  return nil
end

function ROBDispatcher:is_lane_busy(machine_id)
  return LaneState.is_working(self._lanes[machine_id])
end

function ROBDispatcher:is_lane_faulted(machine_id)
  return LaneState.is_faulted(self._lanes[machine_id])
end

function ROBDispatcher:get_debug()
  local lanes = {}
  for mid, lane in pairs(self._lanes) do
    lanes[mid] = {
      state = lane.state,
      current_job_id = lane.current_job_id,
      deadline = lane.deadline,
      last_error = lane.last_error,
    }
  end
  local stable_for = 0
  if self._buf_mon._state == C.DIS_STABILIZING and self._buf_mon._stable_since > 0 then
    stable_for = self._now() - self._buf_mon._stable_since
  end
  local locks = 0
  for _ in pairs(self._lock_mgr._locks) do locks = locks + 1 end
  return {
    buffer_state = self._buf_mon._state,
    pending_jobs = #self._pending_jobs,
    rr_index = self._machine_sel._rr_index,
    stable_for = stable_for,
    batch_claimed = self._buf_mon._batch_claimed,
    lanes = lanes,
    active_locks = locks,
  }
end

return ROBDispatcher
