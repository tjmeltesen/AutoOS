--[[
  AutoOS Subnet Broker — in-game boot helper

  Deploy /home/subnet_broker/ with:
    config.lua, hw.lua, lane_sides.lua, lane_dispatch.lua, central_dispatch.lua,
    maintenance_parse.lua, machine_poll.lua, circuit_manager.lua,
    array_watch.lua, network_protocols.lua, broker_main.lua,
    start.lua, diag.lua, probe_transposer.lua, probe_fluid.lua, fluid_tanks.lua

  Run: loadfile("/home/subnet_broker/start.lua")()
  Watch: lua broker_main.lua
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local REQUIRED = {
  "array_watch.lua", "lane_dispatch.lua", "central_dispatch.lua", "machine_poll.lua",
  "circuit_manager.lua", "descriptor_cache.lua", "interface_stock.lua", "fluid_tanks.lua",
  "network_protocols.lua", "broker_main.lua",
}
local missing = {}
for _, name in ipairs(REQUIRED) do
  local f = io.open(here .. sep .. name, "r")
  if f then f:close() else missing[#missing + 1] = name end
end
if #missing > 0 then
  print("[AutoOS] MISSING files:")
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
print("  Smoke test:  loadfile('" .. here .. "/diag.lua')()")
print("  Find/probe:  loadfile('" .. here .. "/find.lua')('probe')  → also writes find.txt")
print("  Fluid probe: loadfile('" .. here .. "/probe_fluid.lua')('machine_01', 1000, '--xfer')")
print("  Watch loop:  broker_main   (or loadfile('" .. here .. "/broker_main.lua')())")
print("  One tick:    loadfile('" .. here .. "/broker_main.lua')('test')")
print("  Note: broker is headless — no GPU screen; Ctrl+C stops the watch loop")

return Config
