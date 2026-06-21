--[[
  AutoOS — JobDescriptor
  Wraps a JobManifest with runtime status, attempt count, machine assignment.
  Composition over inheritance — manifest is a contained field.
]]
local C = require("rob_core.constants")

local JobDescriptor = {}

--- Create a new job descriptor from a manifest.
--- @return table job record
function JobDescriptor.create(manifest, source, job_id, now)
  return {
    id = job_id,
    source = source or "central",
    status = "pending",
    manifest = manifest,
    attempt = 1,
    created_at = now,
    machine_id = nil,
    started_at = nil,
    last_error = nil,
    last_blocked_reason = nil,
  }
end

--- Set the status of a job by linear scan of the pending_jobs array.
--- @param pending_jobs table  array of job records
--- @param job_id string
--- @param new_status string
function JobDescriptor.set_status(pending_jobs, job_id, new_status)
  for _, job in ipairs(pending_jobs) do
    if job.id == job_id then
      job.status = new_status
      return true
    end
  end
  return false
end

--- Check if a job can be retried.
function JobDescriptor.is_retryable(job, max_attempts)
  return job.attempt < (max_attempts or 2)
end

--- Check if a job has reached a terminal state.
function JobDescriptor.is_terminal(job)
  return job.status == "done" or job.status == "dead"
end

return JobDescriptor
