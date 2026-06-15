--[[
  AutoOS — one-shot AE pattern scan test (broker OC)

  Run from /home/subnet_broker:
    lua scan_test.lua

  Requires subnet_me_address in config.lua (ME controller or interface UUID).
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local component = require("component")
local Config = require("config")
local BrokerRegistry = require("broker_registry")
local RecipeScanner = require("recipe_scanner")

if not Config.subnet_me_address or Config.subnet_me_address == "" then
  print("[scan_test] set subnet_me_address in config.lua")
  return
end

local me = component.proxy(Config.subnet_me_address)
if not me then
  print("[scan_test] no component at " .. Config.subnet_me_address)
  print("  for a,n in component.list() do print(n,a) end")
  return
end

local registry = BrokerRegistry.new(Config)
if Config.registry_persist then registry:load() end
registry:seed_from_config()

print("[scan_test] ME proxy OK — scanning patterns...")
local added, updated = RecipeScanner.scan(me, registry, {
  config = Config,
  log = print,
  now = require("computer").uptime(),
})
print(string.format("[scan_test] done: %d new, %d updated", added, updated))

for key, row in pairs(registry.entries) do
  print(string.format("  uid=%-5d %-24s fluid=%s src=%s",
    row.recipe_uid or 0, key, tostring(row.fluid_label), tostring(row.source)))
end

if (added > 0 or updated > 0) and Config.registry_persist then
  registry:save()
  print("[scan_test] registry saved to " .. tostring(Config.registry_path))
end
