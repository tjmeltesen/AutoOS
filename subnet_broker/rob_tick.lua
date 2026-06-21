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

local function table_len(t)
  if not t then return 0 end
  local n = 0; for _ in pairs(t) do n = n + 1 end; return n
end

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
  local pre_reap = #self._pending_jobs
  JobReaper.reap(self._pending_jobs, self._max_job_attempts)
  if #self._pending_jobs ~= pre_reap then
    self._log(string.format("[ROB] reap: %d -> %d pending jobs", pre_reap, #self._pending_jobs))
  end

  -- Phase 3: Watchdog
  Watchdog.check(self._lanes, self._pending_jobs, now, self._watchdog_grace_s,
    function(mid, lane) self._lock_mgr:release(mid, lane) end,
    self._log)

  -- Phase 4: Buffer monitor
  local job_stabilize = AdmissionControl.job_stabilize_s(self._config)
  local buf_state_before = self._buf_mon._state
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
  -- Log buffer state transitions
  if self._buf_mon._state ~= buf_state_before then
    self._log(string.format("[ROB] buf: %s -> %s", buf_state_before, self._buf_mon._state))
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
  local jobs_assigned = assign_result.events or {}
  if pending_count > 0 and #jobs_assigned == 0 then
    self._log(string.format("[ROB] assign: %d pending, 0 assigned — budget=%d rr=%d locks=%d",
      pending_count,
      self._machine_sel:available_budget(self._lanes),
      self._machine_sel._rr_index,
      table_len(self._lock_mgr._locks)))
  end
  for _, ev in ipairs(assign_result.events or {}) do
    self._log(string.format("[ROB] staged: %s -> %s", tostring(ev.job_id), tostring(ev.machine_id)))
  end

  self._yield_fn = prev_yield

  -- Keep _job_seq in sync (belt-and-suspenders)
  self._job_seq = self._job_seq_ref[1]

  return { events = events, jobs_assigned = jobs_assigned }
end

return RobTick
