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
    print(string.format("[%s] STARTED", task_name))
    while true do
      wake_count = wake_count + 1
      local job = rob:get_assigned_job(machine.id)
      -- print() goes to console, survives log rotation
      print(string.format("[%s] wake=%d job=%s LW=%s",
        task_name, wake_count, tostring(job and job.id or "nil"),
        tostring(LaneWorker ~= nil)))
      if job and LaneWorker then
        print(string.format("[%s] EXEC %s", task_name, job.id))
        local ok_exec, result = pcall(LaneWorker.execute, registry, job, machine.id)
        if not ok_exec then
          print(string.format("[%s] CRASH: %s", task_name, tostring(result)))
          result = { status = "failed", error = "LaneWorker crashed: " .. tostring(result) }
        else
          print(string.format("[%s] DONE status=%s", task_name, tostring(result.status)))
        end
        local results_table = rob:get_results_table()
        results_table[machine.id] = result
        if result.status == "failed" then
          rob:fault_lane(machine.id, result.error or "lane worker failed")
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
