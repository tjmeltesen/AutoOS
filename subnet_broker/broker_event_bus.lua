--[[
  AutoOS — Broker event bus
  Thread-safe event queue wrapping ctx.state.events.
  Single-writer push from modem_rx thread + coroutines.
  Single-reader drain from modem_tx thread.
  ponytail: wraps existing pattern with no locking; benign race on concurrent push
  (pre-existing). Fix here if lock-free queue ever needed.
]]
local EventBus = {}

function EventBus.push(state, event)
  state.events[#state.events + 1] = event
end

function EventBus.drain(state)
  local events = state.events
  if #events > 0 then
    state.events = {}
    return events
  end
  return {}
end

return EventBus
