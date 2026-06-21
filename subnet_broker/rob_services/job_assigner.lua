--[[
  AutoOS — Job Assigner
  Matches pending jobs to available machines, acquires locks, transitions lanes.
]]
local LaneState = require("rob_core.lane_state")

local JobAssigner = {}

--- Assign pending jobs to available machines.
--- @param pending_jobs table  array of job records
--- @param poll_results table  machine_id -> poll status
--- @param machine_selector table  MachineSelector instance
--- @param lock_manager table  LockManager instance
--- @param lanes table  machine_id -> lane record
--- @param config table  Config
--- @param shared_interface_address string|nil
--- @param now_fn function  returns current time
--- @param log_fn function|nil
--- @param yield_fn function|nil
--- @return table { events = {...}, jobs_assigned = {...} }
function JobAssigner.assign(pending_jobs, poll_results, machine_selector, lock_manager,
                            lanes, config, shared_interface_address, now_fn, log_fn, yield_fn)
  local events = {}
  local jobs_assigned = {}

  local machines = config.machines or {}
  local budget = machine_selector:available_budget(lanes)
  if budget <= 0 then return { events = events, jobs_assigned = jobs_assigned } end

  local do_rr = config.do_round_robin ~= false
  local timeout = config.completion_timeout_s or config.staging_timeout_s or 60
  local dispatched = 0

  for _, job in ipairs(pending_jobs) do
    if job.status ~= "pending" then goto next_job end
    if dispatched >= budget then break end
    if yield_fn then yield_fn() end

    local machine, idx = machine_selector:find_available(
      machines, poll_results, lanes, do_rr, nil, log_fn)
    if not machine then break end  -- no available machine, stop trying

    local resources = lock_manager:build_resources(machine, shared_interface_address)
    local ok_lock, lock_err = lock_manager:acquire(machine.id, resources)
    if not ok_lock then
      job.last_blocked_reason = lock_err
      -- Don't advance RR on lock failure — a different job may not need
      -- the same resources and could still use this machine.
      goto next_job
    end

    -- Create or reset lane
    local lane = lanes[machine.id]
    if not lane then
      lane = LaneState.create(machine.id, now_fn)
      lanes[machine.id] = lane
    end

    local now = now_fn and now_fn() or 0
    local deadline = now + timeout
    LaneState.assign(lane, job.id, resources, deadline, now_fn)

    job.status = "running"
    job.machine_id = machine.id
    job.started_at = now

    machine_selector:advance(idx, machines, do_rr)

    events[#events + 1] = {
      type = "central_staged",
      job_id = job.id,
      machine_id = machine.id,
      detail = "job assigned to lane",
    }
    jobs_assigned[#jobs_assigned + 1] = machine.id
    dispatched = dispatched + 1
    ::next_job::
  end

  -- Diagnostic: log when truly-pending jobs exist but nothing dispatched
  if dispatched == 0 and log_fn then
    local pending_count = 0
    for _, job in ipairs(pending_jobs) do
      if job.status == "pending" then pending_count = pending_count + 1 end
    end
    if pending_count > 0 then
      log_fn(string.format("[ROBDispatcher] %d pending jobs — none dispatched (budget=%d)",
        pending_count, budget))
    end
  end

  return { events = events, jobs_assigned = jobs_assigned }
end

return JobAssigner
