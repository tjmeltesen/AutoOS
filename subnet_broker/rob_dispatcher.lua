--[[
  AutoOS — ROB Dispatcher (Reorder Buffer / Atomic Dispatcher)
  Phase 3: Central buffer monitor + job creation + lane assignment + mutex management.

  Replaces central_dispatch.lua and the dispatch-related parts of array_watch.lua
  (step_scheduler, step_central, step_watchdog, _harvest_finished_jobs).

  Architecture:
    - Single tick() entry point called every scheduler cycle — no yields inside.
    - Registry provides cached hardware proxies (no component.proxy() calls here).
    - Lane workers write completion results to a shared table polled by tick().
    - One central batch = one job = one lane. Never split across lanes.

  Internal modules:
    rob_core/          — constants, job_manifest, job_descriptor, lane_state, lock_manager
    rob_services/      — buffer_monitor, admission_control, job_factory, machine_selector,
                         completion_detector, watchdog, job_reaper, job_assigner
    rob_tick.lua       — tick() phase orchestrator
]]

local FluidTanks = require("fluid_tanks")
local C = require("rob_core.constants")
local LockManager = require("rob_core.lock_manager")
local LaneState = require("rob_core.lane_state")
local BufferMonitor = require("rob_services.buffer_monitor")
local MachineSelector = require("rob_services.machine_selector")
local RobTick = require("rob_tick")

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
    or (config.scheduler and config.scheduler.max_parallel_lanes)
    or nil
  self._max_job_attempts = deps.max_job_attempts
    or (config.scheduler and config.scheduler.max_job_attempts)
    or 2
  self._watchdog_grace_s = deps.watchdog_grace_s
    or (config.scheduler and config.scheduler.watchdog_grace_s)
    or 10

  -- Sub-module instances
  self._buf_mon = BufferMonitor.new()
  self._lock_mgr = LockManager.new()
  self._machine_sel = MachineSelector.new(self._max_parallel_lanes)

  -- Job queue (owned by facade)
  self._pending_jobs = {}
  self._job_seq = 0
  self._job_seq_ref = { 0 }  -- mutable ref for job_factory (avoids closure capture)

  -- Lane state
  self._lanes = {}

  -- Completion results table (shared with lane workers)
  self._results = {}

  -- Yield callback for UI mode
  self._yield_fn = nil

  -- Safe yield wrapper (exposed for sub-module callbacks)
  local s = self
  self._safe_yield = function()
    if s._yield_fn then s._yield_fn() end
  end

  -- FluidTanks module reference (for manifest builder callback)
  self._fluid_tanks = FluidTanks

  return self
end

---------------------------------------------------------------------------
-- Public API — tick
---------------------------------------------------------------------------

function ROBDispatcher:tick(poll_results, yield_fn)
  return RobTick.run(self, poll_results, yield_fn)
end

---------------------------------------------------------------------------
-- Public API — results table
---------------------------------------------------------------------------

function ROBDispatcher:get_results_table()
  return self._results
end

---------------------------------------------------------------------------
-- Public API — lane fault / recovery
---------------------------------------------------------------------------

function ROBDispatcher:fault_lane(machine_id, reason)
  local lane = self._lanes[machine_id]
  if not lane then
    lane = LaneState.create(machine_id, self._now)
    self._lanes[machine_id] = lane
  end
  LaneState.fault(lane, reason)
  self._lock_mgr:release(machine_id, lane)
  self._log(string.format("[ROBDispatcher] %s FAULTED: %s", machine_id, reason))
end

function ROBDispatcher:recover_lane(machine_id)
  local lane = self._lanes[machine_id]
  if lane and LaneState.is_faulted(lane) then
    LaneState.recover(lane)
    self._lock_mgr:release(machine_id, lane)
    self._log(string.format("[ROBDispatcher] %s RECOVERED", machine_id))
  end
end

---------------------------------------------------------------------------
-- Public API — transport lock release (called by LaneWorker via registry bridge)
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
  -- Fast tick if buffer is stabilizing, any lane is working, or pending jobs exist
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
  if not lane or not LaneState.is_working(lane) then return nil end
  for _, job in ipairs(self._pending_jobs) do
    if job.id == lane.current_job_id then return job end
  end
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
  return {
    buffer_state = self._buf_mon._state,
    pending_jobs = #self._pending_jobs,
    rr_index = self._machine_sel._rr_index,
    stable_for = stable_for,
    batch_claimed = self._buf_mon._batch_claimed,
    lanes = lanes,
    active_locks = (function()
      local n = 0; for _ in pairs(self._lock_mgr._locks) do n = n + 1 end; return n
    end)(),
  }
end

return ROBDispatcher
