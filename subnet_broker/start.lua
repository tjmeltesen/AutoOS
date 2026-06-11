--[[
  AutoOS Subnet Broker — in-game boot helper (Phase 1)

  HDD layout:
    /home/AutoOS/subnet_broker/
      config.lua, load_balancer.lua, broker_core.lua, start.lua, diag.lua

  Optional top-level boot:
    /home/start.lua → loadfile("/home/AutoOS/subnet_broker/start.lua")()

  Deploy via floppy/USB or wget raw URLs, e.g.:
    wget -f https://raw.githubusercontent.com/tjmeltesen/AutoOS/main/subnet_broker/config.lua
    (repeat for each file — do NOT wget the HTML repo page)

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
