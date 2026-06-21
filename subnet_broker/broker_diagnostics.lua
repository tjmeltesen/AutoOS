--[[
  AutoOS — Broker diagnostics helpers
  Pure formatting functions; no OC API dependencies.
]]
local Diagnostics = {}

function Diagnostics.print_lane_status(poll, machines, log)
  log = log or print
  local results = poll:poll_all()
  for _, m in ipairs(machines) do
    local st = results[m.id]
    if not st or not st.available then
      log(string.format("[Broker] %s OFFLINE — %s",
        m.id, tostring(st and st.fault_message or "no gt_machine proxy")))
    elseif st.healthy then
      log(string.format("[Broker] %s OK (active=%s has_work=%s)",
        m.id, tostring(st.active), tostring(st.has_work)))
    else
      log(string.format("[Broker] %s FAULT — %s", m.id, tostring(st.fault_message)))
    end
  end
end

return Diagnostics
