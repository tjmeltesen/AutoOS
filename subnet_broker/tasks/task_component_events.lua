--[[
  AutoOS — Task: component_events
  Scheduler coroutine that waits for component_available / component_unavailable
  events, marks poll proxy cache stale, and wakes the poll + dispatch cycle.
]]
local Task = {}

function Task.spawn(ctx)
  local Scheduler = require("coroutine_scheduler")
  local Clock = require("dispatch_clock")
  local state = ctx.state

  ctx.scheduler:spawn("component_events", function()
    while true do
      local id = Scheduler.wait_event(function(ev)
        return ev == "component_available" or ev == "component_unavailable"
      end)
      if ctx.poll.mark_proxy_cache_stale then ctx.poll:mark_proxy_cache_stale() end
      state.dirty.components = true
      state.events[#state.events + 1] = { type = id }
      ctx.scheduler:wake("machine_poll")
      Clock.wake_dispatch(ctx.scheduler)
      Scheduler.yield_now()
    end
  end)
end

return Task
