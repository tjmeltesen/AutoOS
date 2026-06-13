--[[
  AutoOS Orchestrator OC — boot helper

  Deploy ALL of these to /home/orchestrator/ on the manager PC (wget from orchestrator/ in the repo):
    network_protocols.lua  hw.lua  orchestrator_config.lua
    registry_store.lua  ae_recipe_registry.lua
    main_net_cache.lua  craft_resolver.lua  main_net_craft.lua
    orchestrator.lua  orchestrator_main.lua  start.lua

  Edit orchestrator_config.lua:
    me_address      — main net ME controller/interface UUID
    broker_address  — subnet broker OC modem (or "" to learn)
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/orchestrator"
package.path = here .. sep .. "?.lua;" .. package.path

local REQUIRED = {
  "network_protocols.lua", "hw.lua", "orchestrator_config.lua",
  "registry_store.lua", "ae_recipe_registry.lua",
  "main_net_cache.lua", "craft_resolver.lua", "main_net_craft.lua",
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
print("  Modem test:  lua modem_comm_test.lua info")
print("               lua modem_comm_test.lua listen   (broker runs listen first)")
print("               lua modem_comm_test.lua ping")
print("  Start loop:  lua orchestrator_main.lua")
print("  Or:          loadfile('" .. here .. "/orchestrator_main.lua')().run()")

return Config
