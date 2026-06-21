--[[
  AutoOS — Job Reaper
  Queue cleanup: removes done/dead jobs, requeues failed jobs with remaining attempts.
]]
local JobDescriptor = require("rob_core.job_descriptor")

local JobReaper = {}

--- Reap jobs from the pending queue.
--- Mutates pending_jobs array in place.
--- @param pending_jobs table  array of job records
--- @param max_attempts number  max retries (default 2)
function JobReaper.reap(pending_jobs, max_attempts)
  max_attempts = max_attempts or 2
  for i = #pending_jobs, 1, -1 do
    local job = pending_jobs[i]
    if job.status == "done" then
      table.remove(pending_jobs, i)
    elseif job.status == "failed" then
      if JobDescriptor.is_retryable(job, max_attempts) then
        job.status = "pending"
        job.attempt = job.attempt + 1
        job.machine_id = nil
        job.started_at = nil
      else
        job.status = "dead"
        table.remove(pending_jobs, i)
      end
    elseif job.status == "dead" then
      table.remove(pending_jobs, i)
    end
  end
end

return JobReaper
