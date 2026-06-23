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
  local log = ctx.log or print

  ctx.scheduler:spawn("central_dispatch", function()
    while true do
      local result = rob:tick(state.poll_results)
      -- Wake lanes that got jobs assigned
      if result.jobs_assigned and #result.jobs_assigned > 0 then
        for _, machine_id in ipairs(result.jobs_assigned) do
          local name = "lane_" .. tostring(machine_id)
          local ok = scheduler:wake(name)
          log(string.format("[CD] wake %s -> %s", name, tostring(ok)))
        end
      end
      -- Emit central events for health/logging
      for _, ev in ipairs(result.events or {}) do
        state.events[#state.events + 1] = ev
      end
      Scheduler.sleep(Clock.fast_interval(cfg, rob))
    end
  end)
end

return Task
