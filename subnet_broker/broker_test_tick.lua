--[[
  AutoOS — Broker test tick (run_once logic)
  Single-tick test mode: polls all machines, runs one dispatcher tick,
  prints debug info, then exits.  Used by BrokerMain.run_once().
]]
local TestTick = {}

function TestTick.run_once(ctx)
  local Diagnostics = require("broker_diagnostics")
  local PollCache = require("broker_poll_cache")

  print(string.format("[Broker] subnet=%s listen=%d orch=%s",
    ctx.config.subnet_id, ctx.listen_port, ctx.config.orchestrator_address or "(none)"))
  Diagnostics.print_lane_status(ctx.poll, ctx.config.machines, ctx.log)

  -- Poll all machines once so dispatcher has data
  local results = ctx.poll:poll_all()
  for mid, r in pairs(results) do
    PollCache.write(ctx, mid, r)
  end

  -- Single dispatcher tick: buffer monitor + job creation + lane assignment
  local tick_result = ctx.rob:tick(ctx.state.poll_results)
  for _, ev in ipairs(tick_result.events or {}) do
    print(string.format("[Broker] event: %s %s", ev.type, tostring(ev.detail or ev.machine_id or "")))
  end

  -- Show lane state
  local dbg = ctx.rob:get_debug()
  print(string.format("[Broker] central state=%s pending=%d batch_claimed=%s",
    dbg.buffer_state, dbg.pending_jobs, tostring(dbg.batch_claimed)))
  for mid, lane in pairs(dbg.lanes) do
    print(string.format("[Broker] %s state=%s job=%s err=%s",
      mid, lane.state, tostring(lane.current_job_id or "none"),
      tostring(lane.last_error or "")))
  end
  print("[Broker] test tick done")
  return true
end

return TestTick
