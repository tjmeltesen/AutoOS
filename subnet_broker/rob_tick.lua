--[[
  AutoOS — ROB tick() orchestrator
  Sequences all 5 dispatch phases each scheduler cycle.
]]
local CompletionDetector = require("rob_services.completion_detector")
local JobReaper = require("rob_services.job_reaper")
local Watchdog = require("rob_services.watchdog")
local BufferMonitor = require("rob_services.buffer_monitor")
local JobAssigner = require("rob_services.job_assigner")
local AdmissionControl = require("rob_services.admission_control")
local JobManifest = require("rob_core.job_manifest")
local JobFactory = require("rob_services.job_factory")

local RobTick = {}

--- Run one full tick cycle.
--- @param self table  ROBDispatcher instance (facade)
--- @param poll_results table  machine_id -> poll status
--- @param yield_fn function|nil
--- @return table { events, jobs_assigned }
function RobTick.run(self, poll_results, yield_fn)
  poll_results = poll_results or {}

  local prev_yield = self._yield_fn
  self._yield_fn = yield_fn
  local now = self._now()

  -- Phase 1: Completion detection
  CompletionDetector.poll(self._results, self._lanes, self._pending_jobs,
    function(mid, lane) self._lock_mgr:release(mid, lane) end,
    self._log)

  -- Phase 2: Job reaping
  JobReaper.reap(self._pending_jobs, self._max_job_attempts)

  -- Phase 3: Watchdog
  Watchdog.check(self._lanes, self._pending_jobs, now, self._watchdog_grace_s,
    function(mid, lane) self._lock_mgr:release(mid, lane) end,
    self._log)

  -- Phase 4: Buffer monitor
  local job_stabilize = AdmissionControl.job_stabilize_s(self._config)
  local buf_result = BufferMonitor.step(
    self._buf_mon, now, self._registry, self._config,
    {
      build_manifest = function()
        return JobManifest.build(self._registry, self._config, self._fluid_tanks, self._safe_yield)
      end,
      enqueue_job = function(manifest)
        return JobFactory.enqueue(manifest, "central", self._registry, self._config,
          self._log, self._now, self._pending_jobs, self._job_seq_ref, self._safe_yield)
      end,
      check_admission = function()
        return AdmissionControl.is_ok(self._registry, self._config,
          self._circuit_manager, self._lanes, self._log, self._safe_yield,
          require("rob_core.constants"))
      end,
      log = self._log,
    },
    self._pending_jobs,
    self._safe_yield,
    job_stabilize
  )
  local events = buf_result.events or {}

  -- Phase 5: Job assignment
  local assign_result = JobAssigner.assign(
    self._pending_jobs, poll_results,
    self._machine_sel, self._lock_mgr, self._lanes,
    self._config, self._config.shared_interface_address,
    self._now, self._log, self._safe_yield
  )
  local jobs_assigned = assign_result.jobs_assigned or {}

  -- Emit assignment events
  for _, ev in ipairs(assign_result.events or {}) do
    events[#events + 1] = ev
  end

  self._yield_fn = prev_yield
  return { events = events, jobs_assigned = jobs_assigned }
end

return RobTick
