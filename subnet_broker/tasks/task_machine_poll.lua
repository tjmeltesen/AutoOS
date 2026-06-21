--[[
  AutoOS — Task: machine_poll
  Scheduler coroutine: round-robin polls one machine per tick, writes
  results to poll cache, wakes the corresponding lane and central_dispatch.
]]
local Task = {}

function Task.spawn(ctx)
  local Scheduler = require("coroutine_scheduler")
  local Clock = require("dispatch_clock")
  local PollCache = require("broker_poll_cache")
  local machines = ctx.config.machines or {}
  local state = ctx.state
  local registry = ctx.registry
  local scheduler = ctx.scheduler
  local cfg = ctx.config
  local rob = ctx.rob

  ctx.scheduler:spawn("machine_poll", function()
    local idx = 1
    while true do
      if #machines > 0 then
        local machine = machines[idx]
        local result = ctx.poll:poll_machine(machine)
        PollCache.write(ctx, machine.id, result)
        PollCache.mark_dirty(ctx, machine.id)
        scheduler:wake("lane_" .. tostring(machine.id))
        scheduler:wake("central_dispatch")
        idx = (idx % #machines) + 1
      end
      Scheduler.sleep(Clock.fast_interval(cfg, rob))
    end
  end)
end

return Task
