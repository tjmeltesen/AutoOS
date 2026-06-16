--[[
  AutoOS Orchestrator OC — boot helper

  Deploy ALL of these to /home/orchestrator/ on the manager PC (wget from orchestrator/ in the repo):
    network_protocols.lua  orchestrator_config.lua
    orchestrator.lua  orchestrator_main.lua  start.lua

  Edit orchestrator_config.lua:
    broker_address  — broker OC modem address for health telemetry
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/orchestrator"
package.path = here .. sep .. "?.lua;" .. package.path

local REQUIRED = {
  "network_protocols.lua", "orchestrator_config.lua",
  "orchestrator.lua", "orchestrator_main.lua",
}

local missing = {}
for _, name in ipairs(REQUIRED) do
  local f = io.open(here .. sep .. name, "r")
  if f then f:close() else missing[#missing + 1] = name end
end
if #missing > 0 then
  print("[AutoOS] MISSING files in " .. here .. ":")
  for _, name in ipairs(missing) do print("   " .. name) end
  print("[AutoOS] wget each file from the repo into /home/orchestrator/")
end

local Config = require("orchestrator_config")
local ok, err = Config.validate(Config)
if ok then
  print("[AutoOS] Orchestrator config: OK — telemetry subnet '" .. tostring(Config.subnet_id) .. "'")
else
  print("[AutoOS] Orchestrator config FAILED: " .. tostring(err))
end

print("[AutoOS] Orchestrator loaded. Usage:")
print("  Modem test:  lua modem_info.lua")
print("               lua modem_listen.lua   (broker runs listen first)")
print("               lua modem_ping.lua")
print("  Start loop:  lua orchestrator_main.lua   (health aggregator)")
print("  Or:          loadfile('" .. here .. "/orchestrator_main.lua')().run()")

return Config
