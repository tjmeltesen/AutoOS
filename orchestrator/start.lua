--[[
  AutoOS Orchestrator OC — boot helper

  The orchestrator PC connects to the MAIN AE2 network (not the subnet).
  Copy network_protocols.lua and hw.lua into /home/orchestrator/.

  Edit orchestrator_config.lua:
    me_address      — main net ME controller/interface UUID
    broker_address  — subnet broker OC modem (or "" to learn)
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/orchestrator"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("orchestrator_config")
local Registry = require("ae_recipe_registry")

local ok, err = Config.validate(Config)
if ok then
  print("[AutoOS] Orchestrator config: OK — main net, subnet '" .. tostring(Config.subnet_id) .. "'")
else
  print("[AutoOS] Orchestrator config FAILED: " .. tostring(err))
end

local registry = Registry.new({ config = Config })
local seeded, seed_err = registry:seed_from_config()
if seeded then
  print("[AutoOS] Recipe registry seeded:")
  for key, row in pairs(registry.entries) do
    print(string.format("   uid=%-5d %-22s circuit=%s fluid=%s",
      row.recipe_uid, key, tostring(row.circuit_damage), tostring(row.fluid_label)))
  end
else
  print("[AutoOS] Registry seed FAILED: " .. tostring(seed_err))
end

print("[AutoOS] Orchestrator loaded. Usage:")
print("  Run loop:  loadfile('" .. here .. "/orchestrator_main.lua')().run()")

return Config
