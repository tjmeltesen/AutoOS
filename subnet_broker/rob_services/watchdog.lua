--[[
  AutoOS — Watchdog
  Timeout detection for WORKING lanes.
]]
local LaneState = require("rob_core.lane_state")
local JobDescriptor = require("rob_core.job_descriptor")

local Watchdog = {}

--- Check all WORKING lanes for timeout.
--- @param lanes table  machine_id -> lane
--- @param pending_jobs table  array of job records
--- @param now number  current time
--- @param watchdog_grace_s number  extra grace period
--- @param release_locks_fn function(machine_id, lane)
--- @param log_fn function|nil
function Watchdog.check(lanes, pending_jobs, now, watchdog_grace_s, release_locks_fn, log_fn)
  for machine_id, lane in pairs(lanes) do
    if LaneState.is_working(lane) then
      local deadline = lane.deadline or 0
      local grace = watchdog_grace_s or 10
      if now > deadline + grace then
        local detail = string.format("watchdog timeout: deadline=%.1f now=%.1f grace=%.1f",
          deadline, now, grace)
        if log_fn then
          log_fn(string.format("[ROBDispatcher] %s %s (job %s)", machine_id, detail,
            tostring(lane.current_job_id)))
        end
        lane.last_error = detail
        JobDescriptor.set_status(pending_jobs, lane.current_job_id, "failed")
        release_locks_fn(machine_id, lane)
        LaneState.fault(lane, detail)
      end
    end
  end
end

return Watchdog
