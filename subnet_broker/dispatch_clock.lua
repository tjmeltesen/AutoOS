--[[
  AutoOS — Dispatch clock helpers
  Cadence control: fast_interval picks poll rate, wake_dispatch wakes all dispatch tasks.
]]
local DispatchClock = {}

function DispatchClock.fast_interval(cfg, rob)
  if rob:any_fast_tick() then
    return cfg.monitor_poll_s or 0.15
  end
  return cfg.tick_interval or 1.0
end

function DispatchClock.wake_dispatch(scheduler)
  scheduler:wake("central_dispatch")
  scheduler:wake_prefix("lane_")
end

return DispatchClock
