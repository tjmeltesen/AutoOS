--[[
  AutoOS — Broker entry point
  Run in-game:
    broker_entry              -- or: lua broker_entry.lua
    loadfile("/home/subnet_broker/broker_entry.lua")()
    loadfile("/home/subnet_broker/broker_entry.lua")("test")  -- one tick, then exit

  When require("broker_entry") is called, returns the BrokerMain module table
  without autostarting.  Autostart only fires when run as the main script.
]]
local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local mode = ({...})[1]
local BrokerMain = require("broker_main")

local function should_autostart()
  if mode == "broker_main" then return false end
  if mode == "test" or mode == "once" then return true end
  -- ponytail: OpenOS has no arg[]; lua broker_entry.lua runs under /bin/lua — skip require() only
  local info = debug.getinfo(2, "S")
  if info and info.what == "C" then return false end
  return true
end

if should_autostart() then
  if mode == "test" or mode == "once" then
    BrokerMain.run_once()
  else
    local ok, err = xpcall(BrokerMain.run, debug.traceback)
    if not ok then print("[Broker] FATAL:\n" .. tostring(err)) end
  end
end

return BrokerMain
