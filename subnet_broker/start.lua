--[[
  AutoOS Subnet Broker — in-game boot helper

  HDD layout:
    /home/subnet_broker/
      config.lua, hw.lua, lane_sides.lua, load_balancer.lua,
      maintenance_parse.lua, machine_poll.lua, descriptor_cache.lua,
      fluid_lane.lua, circuit_manager.lua, broker_core.lua,
      network_protocols.lua, broker_main.lua,
      start.lua, diag.lua, test.lua, pre_p3_checklist.lua

  Deploy via floppy/USB or wget raw URLs (do NOT wget the HTML repo page):
    wget -f .../subnet_broker/config.lua /home/subnet_broker/config.lua
    wget -f .../subnet_broker/hw.lua /home/subnet_broker/hw.lua
    wget -f .../subnet_broker/lane_sides.lua /home/subnet_broker/lane_sides.lua
    wget -f .../subnet_broker/load_balancer.lua /home/subnet_broker/load_balancer.lua
    wget -f .../subnet_broker/maintenance_parse.lua /home/subnet_broker/maintenance_parse.lua
    wget -f .../subnet_broker/machine_poll.lua /home/subnet_broker/machine_poll.lua
    wget -f .../subnet_broker/descriptor_cache.lua /home/subnet_broker/descriptor_cache.lua
    wget -f .../subnet_broker/fluid_lane.lua /home/subnet_broker/fluid_lane.lua
    wget -f .../subnet_broker/circuit_manager.lua /home/subnet_broker/circuit_manager.lua
    wget -f .../subnet_broker/broker_core.lua /home/subnet_broker/broker_core.lua
    wget -f .../subnet_broker/network_protocols.lua /home/subnet_broker/network_protocols.lua
    wget -f .../subnet_broker/broker_main.lua /home/subnet_broker/broker_main.lua
    wget -f .../subnet_broker/diag.lua /home/subnet_broker/diag.lua
    wget -f .../subnet_broker/test.lua /home/subnet_broker/test.lua
    wget -f .../subnet_broker/pre_p3_checklist.lua /home/subnet_broker/pre_p3_checklist.lua
    wget -f .../subnet_broker/start.lua /home/subnet_broker/start.lua

  Edit config.lua with real component UUIDs from:
    local c = require("component"); for a, n in c.list() do print(n, a) end

  This file only loads modules and prints usage — it does NOT touch hardware.
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local P3_REQUIRED = { "network_protocols.lua", "broker_main.lua" }
local missing = {}
for _, name in ipairs(P3_REQUIRED) do
  local f = io.open(here .. sep .. name, "r")
  if f then f:close() else missing[#missing + 1] = name end
end
if #missing > 0 then
  print("[AutoOS] MISSING for Phase 3 modem slave:")
  for _, name in ipairs(missing) do print("   " .. name) end
end

local Config = require("config")
local BrokerCore = require("broker_core")

local ok, err = Config.validate(Config)
if ok then
  print("[AutoOS] Config validate: OK — subnet '" .. tostring(Config.subnet_id) .. "'")
else
  print("[AutoOS] Config validate FAILED: " .. tostring(err))
end

print("[AutoOS] Broker loaded. Usage:")
print("  Modem test:  lua modem_comm_test.lua info")
print("               lua modem_comm_test.lua listen   (manager runs ping)")
print("               lua modem_comm_test.lua ping")
print("  Smoke test:  loadfile('" .. here .. "/diag.lua')()")
print("  Full lines:  loadfile('" .. here .. "/test.lua')()")
print("  Pre-P3 gate: loadfile('" .. here .. "/pre_p3_checklist.lua')()")
print("  P3 slave:    lua broker_main.lua")
print("  One lane:    require('broker_core').manual_lane_test('machine_01', 'polyethylene', 1000)")
print("  Full batch:  require('broker_core').process_batch('polyethylene', 3000)")
print("  Multi jobs:  require('broker_core').process_multi({")
print("                 { recipe='polyethylene', volume=2000, lanes={'machine_01','machine_02'} },")
print("                 { recipe='molten_soldering_alloy', volume=2880, lanes={'machine_03','machine_04'} },")
print("               })")

return BrokerCore
