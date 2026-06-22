--[[
  AutoOS — Task: lane_worker
  Per-machine scheduler coroutine.  Pulls assigned job from ROB, executes
  via LaneWorker (optional), posts result, wakes central_dispatch on completion.
  One coroutine per config machine.
]]
local Task = {}

function Task.spawn(ctx, machine)
  local Scheduler = require("coroutine_scheduler")
  local Clock = require("dispatch_clock")
  local rob = ctx.rob
  local registry = ctx.registry
  local scheduler = ctx.scheduler
  local cfg = ctx.config
  local LaneWorker = ctx._lane_worker_module
  local log = ctx.log or print

  local task_name = "lane_" .. tostring(machine.id)
  log(string.format("[BS] spawning %s", task_name))
  ctx.scheduler:spawn(task_name, function()
    local wake_count = 0
    local did_run = false
    while true do
      wake_count = wake_count + 1
      local ok_get, job = pcall(rob.get_assigned_job, rob, machine.id)
      if not ok_get then
        log(string.format("!!! %s get_assigned_job CRASH: %s", task_name, tostring(job)))
      elseif job then
        did_run = true
        log(string.format("!!! %s RUN job=%s wake=%d", task_name, job.id, wake_count))
        local ok_exec, result = pcall(LaneWorker.execute, registry, job, machine.id)
        if not ok_exec then
          result = { status = "failed", error = "LaneWorker crashed: " .. tostring(result) }
          log(string.format("!!! %s LW_CRASH: %s", task_name, tostring(result.error)))
        else
          log(string.format("!!! %s LW_DONE: %s", task_name, tostring(result.status)))
        end
        local rt = rob:get_results_table()
        if rt then rt[machine.id] = result end
        if result.status == "failed" then
          pcall(rob.fault_lane, rob, machine.id, result.error or "lane worker failed")
        end
        scheduler:wake("central_dispatch")
      else
        -- Woke but no job assigned.  Log periodically to confirm liveness.
        if wake_count % 20 == 1 then
          log(string.format("!!! %s woke=%d — no job (did_run=%s)",
            task_name, wake_count, tostring(did_run)))
        end
      end
      -- Write did_run flag onto the dispatcher so periodic dump can see it
      rob._lane_ran = (rob._lane_ran or {})
      rob._lane_ran[machine.id] = did_run
      Scheduler.yield_now()
      Scheduler.sleep(Clock.fast_interval(cfg, rob))
    end
  end)
end

function Task.spawn_all(ctx)
  local machines = ctx.config.machines or {}
  for _, machine in ipairs(machines) do
    Task.spawn(ctx, machine)
  end
end

return Task
