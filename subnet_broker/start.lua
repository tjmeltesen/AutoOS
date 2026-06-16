--[[
  AutoOS Subnet Broker — in-game boot helper

  HDD layout (array watch mode):
    /home/subnet_broker/
      config.lua, hw.lua, lane_sides.lua, maintenance_parse.lua,
      machine_poll.lua, descriptor_cache.lua, circuit_manager.lua,
      circuit_loop.lua, array_watch.lua, network_protocols.lua, broker_main.lua,
      start.lua, diag.lua, probe_transposer.lua, test_recover_transfer.lua

  Deploy via floppy/USB or wget raw URLs (do NOT wget the HTML repo page):
    wget -f .../subnet_broker/config.lua /home/subnet_broker/config.lua
    wget -f .../subnet_broker/hw.lua /home/subnet_broker/hw.lua
    wget -f .../subnet_broker/lane_sides.lua /home/subnet_broker/lane_sides.lua
    wget -f .../subnet_broker/maintenance_parse.lua /home/subnet_broker/maintenance_parse.lua
    wget -f .../subnet_broker/machine_poll.lua /home/subnet_broker/machine_poll.lua
    wget -f .../subnet_broker/descriptor_cache.lua /home/subnet_broker/descriptor_cache.lua
    wget -f .../subnet_broker/circuit_manager.lua /home/subnet_broker/circuit_manager.lua
    wget -f .../subnet_broker/circuit_loop.lua /home/subnet_broker/circuit_loop.lua
    wget -f .../subnet_broker/network_protocols.lua /home/subnet_broker/network_protocols.lua
    wget -f .../subnet_broker/array_watch.lua /home/subnet_broker/array_watch.lua
    wget -f .../subnet_broker/probe_transposer.lua /home/subnet_broker/probe_transposer.lua
    wget -f .../subnet_broker/test_recover_transfer.lua /home/subnet_broker/test_recover_transfer.lua
    wget -f .../subnet_broker/diag.lua /home/subnet_broker/diag.lua
    wget -f .../subnet_broker/start.lua /home/subnet_broker/start.lua

  Edit config.lua with real component UUIDs from:
    local c = require("component"); for a, n in c.list() do print(n, a) end

  This file only loads modules and prints usage — it does NOT touch hardware.
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local P3_REQUIRED = {
  "array_watch.lua", "machine_poll.lua", "circuit_manager.lua",
  "circuit_loop.lua",
  "network_protocols.lua", "broker_main.lua",
}
local missing = {}
for _, name in ipairs(P3_REQUIRED) do
  local f = io.open(here .. sep .. name, "r")
  if f then f:close() else missing[#missing + 1] = name end
end
if #missing > 0 then
  print("[AutoOS] MISSING for Phase 3 broker watch:")
  for _, name in ipairs(missing) do print("   " .. name) end
end

local Config = require("config")
local ok, err = Config.validate(Config)
if ok then
  print("[AutoOS] Config validate: OK — subnet '" .. tostring(Config.subnet_id) .. "'")
else
  print("[AutoOS] Config validate FAILED: " .. tostring(err))
end

print("[AutoOS] Broker loaded. Usage:")
print("  Modem test:  lua modem_info.lua")
print("               lua modem_listen.lua   (manager runs ping)")
print("               lua modem_ping.lua")
print("  Smoke test:  loadfile('" .. here .. "/diag.lua')()")
print("  Face probe:  loadfile('" .. here .. "/probe_transposer.lua')()")
print("  Xfer probe:  loadfile('" .. here .. "/test_recover_transfer.lua')('machine_01')")
print("  Watch loop:  lua broker_main.lua   (health + circuit recover only)")
print("  Orchestrator lua orchestrator_main.lua   (aggregates broker telemetry)")

return Config
