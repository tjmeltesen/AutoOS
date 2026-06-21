--[[
  AutoOS — Task: heartbeat (modem_tx)
  OC thread that periodically sends BROKER_HEALTH telemetry per machine
  and drains + relays event bus entries as BROKER_EVENT messages to the
  orchestrator.
]]
local Task = {}

function Task.spawn(ctx)
  local thread = require("thread")
  local Protocols = require("network_protocols")
  local EventBus = require("broker_event_bus")
  local modem = ctx.modem
  local cfg = ctx.config
  local orch_addr = cfg.orchestrator_address or ""
  local orch_port = ctx.orch_port
  local subnet_id = cfg.subnet_id or "?"
  local interval = cfg.heartbeat_interval_s or 10
  local machines = cfg.machines or {}
  local state = ctx.state

  local tx = thread.create(function()
    while true do
      os.sleep(interval)
      if orch_addr == "" then goto skip_tx end
      -- Health telemetry: one BROKER_HEALTH per machine with poll data
      for _, m in ipairs(machines) do
        local ok, pr = pcall(function() return state.poll_results[m.id] end)
        if ok and pr then
          local state_str = pr.healthy and "OK" or "FAULT"
          local detail = pr.fault_message or ""
          modem.send(orch_addr, orch_port,
            Protocols.broker_health(subnet_id, m.id, state_str, detail))
        end
      end
      -- Drain and relay dispatcher events as BROKER_EVENT
      local events = EventBus.drain(state)
      for _, ev in ipairs(events) do
        local kind = ev.type or ev.kind or "?"
        modem.send(orch_addr, orch_port,
          Protocols.broker_event(subnet_id, kind, ev.label or "",
            ev.volume or 0, ev.job_id or ev.machine_id or ""))
      end
      ::skip_tx::
    end
  end)
  tx:detach()
  ctx._modem_threads[#ctx._modem_threads + 1] = tx
end

return Task
