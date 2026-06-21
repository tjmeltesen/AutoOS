--[[
  AutoOS — Completion Detector
  Polls shared _results table, transitions lanes based on completion status.
]]
local LaneState = require("rob_core.lane_state")
local JobDescriptor = require("rob_core.job_descriptor")

local CompletionDetector = {}

--- Poll results table for completed jobs.
--- @param results table  machine_id -> { status, error }
--- @param lanes table     machine_id -> lane record
--- @param pending_jobs table  array of job records
--- @param release_locks_fn function(machine_id, lane)
--- @param log_fn function|nil
function CompletionDetector.poll(results, lanes, pending_jobs, release_locks_fn, log_fn)
  for machine_id, result in pairs(results) do
    local lane = lanes[machine_id]
    if lane and LaneState.is_working(lane) then
      if result.status == "done" then
        if log_fn then
          log_fn(string.format("[ROBDispatcher] %s job complete: %s", machine_id, tostring(lane.current_job_id)))
        end
        lane.last_error = nil
        JobDescriptor.set_status(pending_jobs, lane.current_job_id, "done")
        release_locks_fn(machine_id, lane)
        LaneState.complete(lane)
      elseif result.status == "failed" then
        if log_fn then
          log_fn(string.format("[ROBDispatcher] %s job failed: %s — %s", machine_id,
            tostring(lane.current_job_id), tostring(result.error)))
        end
        lane.last_error = result.error or "lane worker reported failure"
        JobDescriptor.set_status(pending_jobs, lane.current_job_id, "failed")
        release_locks_fn(machine_id, lane)
        LaneState.fault(lane, result.error or "lane worker reported failure")
      end
      -- Consume result
      results[machine_id] = nil
    end
  end
end

return CompletionDetector
