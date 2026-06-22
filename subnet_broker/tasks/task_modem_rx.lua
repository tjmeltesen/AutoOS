--[[
  AutoOS — Task: modem_rx
  OC thread that pulls modem_message events, responds to PING for
  modem_comm_test compat, and pushes parsed packets to the event bus.
]]
local Task = {}

function Task.spawn(ctx)
  local thread = require("thread")
  local event = require("event")
  local Protocols = require("network_protocols")
  local FaultNet = require("fault_net")
  local modem = ctx.modem
  local orch_port = ctx.orch_port
  local state = ctx.state
  local log = ctx.log or print
  local faults = ctx.faults or { items = {}, head = 1, count = 0, max = 100 }

  local rx = thread.create(function()
    while true do
      local _, _, from, _, _, message = event.pull("modem_message")
      local ok, err = pcall(function()
        -- Back-compat: respond to PING from modem_comm_test
        if type(message) == "string" and message == "PING" then
          pcall(modem.send, modem, from, orch_port, "PONG")
        else
          local pkt = Protocols.parse(message)
          if pkt then
            state.events[#state.events + 1] = { type = "modem_message", from = from, packet = pkt }
          end
        end
      end)
      if not ok then
        FaultNet.capture({ log = log, faults = faults }, "net.modem_rx", tostring(err),
          { port = orch_port, sender = tostring(from) })
      end
    end
  end)
  rx:detach()
  ctx._modem_threads[#ctx._modem_threads + 1] = rx
end

return Task
