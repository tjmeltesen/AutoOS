--[[
  AutoOS — Task: central_dispatch
  Scheduler coroutine: calls rob:tick() each cycle, wakes lanes that got
  jobs assigned, emits central events for health/logging.
]]
local Task = {}

function Task.spawn(ctx)
  local Scheduler = require("coroutine_scheduler")
  local Clock = require("dispatch_clock")
  local rob = ctx.rob
  local state = ctx.state
  local scheduler = ctx.scheduler
  local cfg = ctx.config

  ctx.scheduler:spawn("central_dispatch", function()
    while true do
      local result = rob:tick(state.poll_results)
      -- Wake lanes that got jobs assigned
      for _, machine_id in ipairs(result.jobs_assigned or {}) do
        scheduler:wake("lane_" .. tostring(machine_id))
      end
      -- Emit central events for health/logging
      for _, ev in ipairs(result.events or {}) do
        state.events[#state.events + 1] = ev
      end
      Scheduler.yield_now()
      Scheduler.sleep(Clock.fast_interval(cfg, rob))
    end
  end)
end

return Task
