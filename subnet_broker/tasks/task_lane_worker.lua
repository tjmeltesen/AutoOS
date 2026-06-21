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
  local LaneWorker = ctx._lane_worker_module  -- set by bootstrap during pcall load

  ctx.scheduler:spawn("lane_" .. tostring(machine.id), function()
    while true do
      local job = rob:get_assigned_job(machine.id)
      if job and LaneWorker then
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
