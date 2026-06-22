--[[
  AutoOS — Broker diagnostics helpers
  Pure formatting functions; no OC API dependencies.
]]
local Diagnostics = {}

function Diagnostics.print_lane_status(poll, machines, log)
  log = log or print
  local results = poll:poll_all()
  for _, m in ipairs(machines) do
    local st = results[m.id]
    if not st or not st.available then
      log(string.format("[Broker] %s OFFLINE — %s",
        m.id, tostring(st and st.fault_message or "no gt_machine proxy")))
    elseif st.healthy then
      log(string.format("[Broker] %s OK (active=%s has_work=%s)",
        m.id, tostring(st.active), tostring(st.has_work)))
    else
      log(string.format("[Broker] %s FAULT — %s", m.id, tostring(st.fault_message)))
    end
  end
end

--- Print current ROB dispatcher state summary (headless-safe).
---@param rob table   ROBDispatcher instance
---@param log function|nil
function Diagnostics.print_rob_state(rob, log)
  log = log or print
  local dbg = rob:get_debug()
  log(string.format("[DIAG] ROB: buf=%s pending=%d rr=%d locks=%d batch=%s stable=%.1fs",
    tostring(dbg.buffer_state), dbg.pending_jobs, dbg.rr_index,
    dbg.active_locks, tostring(dbg.batch_claimed), dbg.stable_for or 0))
  for mid, lane in pairs(dbg.lanes or {}) do
    log(string.format("[DIAG]   lane %s: state=%s job=%s deadline=%.0f err=%s",
      tostring(mid), tostring(lane.state),
      tostring(lane.current_job_id), lane.deadline or 0,
      tostring(lane.last_error or "")))
  end
end

--- Print recent N faults from the in-memory ring buffer (headless-safe).
---@param ctx table   context with ctx.faults ring buffer
---@param n number|nil  how many recent faults to show (default 10)
---@param log function|nil
function Diagnostics.print_recent_faults(ctx, n, log)
  log = log or print
  local f = ctx.faults
  if not f or not f.items or f.count == 0 then
    log("[DIAG] faults: (none)")
    return
  end
  n = n or 10
  local shown = 0
  -- Walk ring buffer from oldest to newest
  local start = f.head - f.count
  if start < 1 then start = start + f.max end
  for i = 0, f.count - 1 do
    local idx = ((start - 1 + i) % f.max) + 1
    local entry = f.items[idx]
    if entry and shown < n then
      shown = shown + 1
      log(string.format("[DIAG] fault #%d: %s | %s | %s",
        shown, tostring(entry.ts), tostring(entry.tag), tostring(entry.err)))
    end
  end
  if f.count > n then
    log(string.format("[DIAG] ... and %d more faults (total=%d)", f.count - n, f.count))
  end
end

return Diagnostics
