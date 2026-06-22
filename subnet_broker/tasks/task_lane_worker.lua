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
    log(string.format("[%s] STARTED rob=%s has_lanes=%s",
      task_name, tostring(rob):sub(8), tostring(rob._lanes ~= nil)))
    while true do
      wake_count = wake_count + 1
      local job = rob:get_assigned_job(machine.id)
      log(string.format("[%s] wake=%d job=%s LaneWorker=%s",
        task_name, wake_count, tostring(job and job.id or "nil"),
        tostring(LaneWorker ~= nil)))
      if not job then
        -- Dump full state to diagnose
        if wake_count <= 3 then
          local l = rob._lanes and rob._lanes[machine.id]
          log(string.format("[%s] state: _lanes_exists=%s lane=%s lane_state=%s pending=%d locked=%d",
            task_name, tostring(rob._lanes ~= nil),
            tostring(l ~= nil),
            l and l.state or "nil",
            #(rob._pending_jobs or {}),
            (function() local n=0; if rob._lock_mgr then for _ in pairs(rob._lock_mgr._locks or {}) do n=n+1 end end; return n end)()))
        end
      end
      if job and LaneWorker then
        log(string.format("[%s] GOT_JOB %s — executing", task_name, job.id))
        local ok_exec, result = pcall(LaneWorker.execute, registry, job, machine.id)
        if not ok_exec then
          result = { status = "failed", error = "LaneWorker crashed: " .. tostring(result) }
          log(string.format("[%s] LaneWorker CRASHED: %s", task_name, tostring(result.error)))
        else
          log(string.format("[%s] LaneWorker done: status=%s", task_name, tostring(result.status)))
        end
        local results_table = rob:get_results_table()
        results_table[machine.id] = result
        if result.status == "failed" then
          rob:fault_lane(machine.id, result.error or "lane worker failed")
          log(string.format("[%s] FAULTED: %s", task_name, tostring(result.error)))
        end
        scheduler:wake("central_dispatch")
      end
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
