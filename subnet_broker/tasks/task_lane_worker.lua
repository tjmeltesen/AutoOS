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
  ctx.scheduler:spawn(task_name, function()
    local wake_count = 0
    while true do
      wake_count = wake_count + 1
      local job = rob:get_assigned_job(machine.id)
      -- Log every wake until we get a job, then go quiet
      if not job then
        local lane_state = "?"
        if rob._lanes and rob._lanes[machine.id] then
          lane_state = rob._lanes[machine.id].state or "?"
        end
        if wake_count <= 5 or wake_count % 20 == 1 then
          log(string.format("[LaneTask] %s wake=%d state=%s NO_JOB",
            machine.id, wake_count, lane_state))
        end
      end
      if job and LaneWorker then
        log(string.format("[LaneTask] %s wake=%d GOT_JOB %s", machine.id, wake_count, job.id))
        local ok_exec, result = pcall(LaneWorker.execute, registry, job, machine.id)
        if not ok_exec then
          result = { status = "failed", error = "LaneWorker crashed: " .. tostring(result) }
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
