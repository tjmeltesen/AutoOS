--[[
  AutoOS — Lane Completion (Phase 5)
  Wait for GT machine to finish processing.  Contains the full
  completion_ready() decision tree — the most debug-sensitive code.
  Extracted from lane_worker.lua.
]]

local LaneContext = require("lane_context")

local Completion = {}

--- Wait for machine completion.
---@param ctx table  lane context
---@return boolean ok
---@return string|nil err
function Completion.run(ctx)
  local config = ctx.config
  local staging_timeout_s = ctx.staging_timeout_s

  ctx:log(string.format("[LaneWorker] %s Phase5: waiting for machine completion (mode=%s timeout=%.0fs)",
    ctx.machine_id, config.completion_mode or "both",
    config.completion_timeout_s or staging_timeout_s))

  -- ponytail: phase5 hard deadline — watchdog double-check
  ctx.phase5_deadline_at = ctx.now_fn() + (config.completion_timeout_s or ctx.staging_timeout_s or 60)

  local complete_start = ctx.now_fn()
  local saw_active = false
  local quiet_drained_since = nil
  local completion_mode = config.completion_mode or "both"
  local quiet_failsafe_s = config.completion_quiet_failsafe_s
    or (config.central and config.central.completion_quiet_failsafe_s)
    or 2
  local circuit_bus_slot = ctx.circuit_bus_slot

  local _stuck_warned = false

  -- The decision tree — every return path documented in the analysis.
  local function completion_ready()
    -- ponytail: one-shot stuck warning at half-timeout
    if not _stuck_warned and ctx.now_fn() - complete_start > (completion_timeout * 0.5) then
      _stuck_warned = true
      ctx:log(string.format("[LaneWorker] %s Phase5 STUCK_WARNING: elapsed=%.1fs timeout=%.1fs poll=%s",
        ctx.machine_id, ctx.now_fn() - complete_start, completion_timeout,
        tostring(ctx.registry.get_poll_result(ctx.machine_id) and "ok" or "nil")))
    end

    local poll = ctx.registry.get_poll_result(ctx.machine_id)
    if poll and poll.active then
      if not saw_active then
        saw_active = true
        ctx:log(string.format("[LaneWorker] %s Phase5: machine became active", ctx.machine_id))
      end
      quiet_drained_since = nil
    end
    local drained = LaneContext.bus_drained(ctx.item_tp, ctx.machine, circuit_bus_slot)
    if not drained then
      quiet_drained_since = nil
      return false
    end
    if completion_mode == "drain" then
      ctx:log(string.format("[LaneWorker] %s Phase5: bus drained -> complete", ctx.machine_id))
      return true
    end

    if not saw_active then
      -- nil-poll guard: treat missing poll as "not active, no work"
      if (not poll) or (poll and not poll.active and not poll.has_work) then
        quiet_drained_since = quiet_drained_since or ctx.now_fn()
        if ctx.now_fn() - quiet_drained_since >= quiet_failsafe_s then
          ctx:log(string.format("[LaneWorker] %s Phase5: quiet-drain failsafe (%.1fs)",
            ctx.machine_id, ctx.now_fn() - quiet_drained_since))
          return true
        end
      else
        quiet_drained_since = nil
      end
      return false
    end

    if completion_mode == "adapter" then
      local done = poll and not poll.active
      if done then
        ctx:log(string.format("[LaneWorker] %s Phase5: adapter went inactive -> complete", ctx.machine_id))
      end
      return done
    end
    -- nil-poll guard: if we saw it active and poll goes nil, assume finished
    if not poll or not poll.active then
      ctx:log(string.format("[LaneWorker] %s Phase5: machine finished -> complete (poll=%s)",
        ctx.machine_id, tostring(poll and "ok" or "nil")))
      return true
    end
    return false
  end

  local completion_timeout = config.completion_timeout_s or staging_timeout_s
  local ok_comp, comp_err = LaneContext.await_delivery(ctx,
    completion_ready, completion_timeout, complete_start, "completion")
  if not ok_comp then return ctx:fail(comp_err) end

  ctx:log(string.format("[LaneWorker] %s Phase5: complete (%.1fs)",
    ctx.machine_id, ctx.now_fn() - complete_start))
  return true
end

return Completion
