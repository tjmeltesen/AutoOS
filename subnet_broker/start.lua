--[[
  AutoOS Subnet Broker — in-game boot helper (Phase 1)

  HDD layout:
    /home/AutoOS/subnet_broker/
      config.lua, load_balancer.lua, descriptor_cache.lua, broker_core.lua, circuit_manager.lua,
      machine_poll.lua, maintenance_parse.lua, start.lua, diag.lua

  Optional top-level boot:
    /home/start.lua → loadfile("/home/AutoOS/subnet_broker/start.lua")()

  Deploy via floppy/USB or wget raw URLs (do NOT wget the HTML repo page):
    wget -f .../subnet_broker/config.lua /home/AutoOS/subnet_broker/config.lua
    wget -f .../subnet_broker/load_balancer.lua /home/AutoOS/subnet_broker/load_balancer.lua
    wget -f .../subnet_broker/maintenance_parse.lua /home/AutoOS/subnet_broker/maintenance_parse.lua
    wget -f .../subnet_broker/machine_poll.lua /home/AutoOS/subnet_broker/machine_poll.lua
    wget -f .../subnet_broker/lane_sides.lua /home/AutoOS/subnet_broker/lane_sides.lua
    wget -f .../subnet_broker/descriptor_cache.lua /home/AutoOS/subnet_broker/descriptor_cache.lua
    wget -f .../subnet_broker/fluid_lane.lua /home/AutoOS/subnet_broker/fluid_lane.lua
    wget -f .../subnet_broker/circuit_manager.lua /home/AutoOS/subnet_broker/circuit_manager.lua
    wget -f .../subnet_broker/broker_core.lua /home/AutoOS/subnet_broker/broker_core.lua
    wget -f .../subnet_broker/diag.lua /home/AutoOS/subnet_broker/diag.lua
    wget -f .../subnet_broker/start.lua /home/AutoOS/subnet_broker/start.lua

  Edit config.lua with real component UUIDs from:
    local c = require("component"); for a,n in c.list() do print(n,a) end

  Run diag first: loadfile("/home/AutoOS/subnet_broker/diag.lua")()
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/AutoOS/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local BrokerCore = require("broker_core")

-- README §4 verification: 15,000L / 1440L = 10 ops → 3, 3, 2, 2
BrokerCore.process_batch("molten_soldering_alloy", 15000)
