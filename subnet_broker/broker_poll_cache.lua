--[[
  AutoOS — Broker poll cache
  Single-writer for poll results.  Writes to BOTH state.poll_results
  and registry._poll_results in one call so they never drift apart.
]]
local PollCache = {}

function PollCache.write(ctx, machine_id, result)
  ctx.state.poll_results[machine_id] = result
  ctx.registry._poll_results[machine_id] = result
end

function PollCache.mark_dirty(ctx, machine_id)
  ctx.state.dirty[machine_id] = true
end

return PollCache
