--[[
  AutoOS — Task: central_input_events
  Scheduler coroutine that waits for inventory_changed / tank_changed /
  me_interface_changed events and wakes central_dispatch.
]]
local Task = {}

function Task.spawn(ctx)
  local Scheduler = require("coroutine_scheduler")
  local state = ctx.state

  ctx.scheduler:spawn("central_input_events", function()
    while true do
      local id = Scheduler.wait_event(function(ev)
        return ev == "inventory_changed"
          or ev == "tank_changed"
          or ev == "me_interface_changed"
      end)
      state.events[#state.events + 1] = { type = id }
      ctx.scheduler:wake("central_dispatch")
      Scheduler.yield_now()
    end
  end)
end

return Task
