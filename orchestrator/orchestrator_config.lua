--[[
  AutoOS — Orchestrator OC config

  The Orchestrator runs on a SEPARATE OpenComputer from the broker.

  Hardware on the orchestrator PC:
    * one ME adapter on the MAIN AE2 network → me_address
    * a network card / modem → modem_port
    * broker OC modem address → broker_address (or "" to learn)

  The broker stays on the subnet with the four machines. The manager never
  touches lane hardware; it only reads the main net and sends wireless jobs.

  recipe_baselines: same as broker plus recipe_uid and display_name.
]]

local Config = {}

Config.subnet_id = "universal_chemical_mv_01"

-- Main net ME adapter UUID (component.list() on the orchestrator OC).
Config.me_address = "60ea8e78-a000-4cac-b852-ef6a811193fe"

Config.broker_address = "fc2d6329-4d3e-4a03-a915-9e096d29f3a9"

Config.modem_port = 105
Config.broker_modem_port = 106

Config.recipe_baselines = {
  ["molten_soldering_alloy"] = {
    recipe_uid = 256,
    display_name = "Soldering Alloy",
    fluid_label = "Molten Soldering Alloy",
    fluid_requirement = 1440,
    circuit_damage = 14,
    kind = "fluid",
  },
  ["polyethylene"] = {
    recipe_uid = 257,
    display_name = "Polyethylene",
    fluid_label = "Ethylene",
    fluid_requirement = 1000,
    circuit_damage = 18,
    kind = "fluid",
  },
}

Config.orchestrator = {
  tick_interval = 1.0,
  uid_bits = 16,
  uid_min = 256,
  token_item_name = "gregtech:gt.integrated_circuit",
  circuit_item_name = "gregtech:gt.integrated_circuit",
  craftable_cache_s = 600,
  registry_persist = true,
  registry_path = "/home/orchestrator/recipe_registry.lua",
  min_dispatch_mB = nil,
  -- When a main-net craft finishes, send DISPATCH_JOB to the subnet broker.
  dispatch_on_craft_done = true,
}

function Config.validate(cfg)
  cfg = cfg or Config

  if type(cfg.subnet_id) ~= "string" or cfg.subnet_id == "" then
    return nil, "subnet_id required"
  end

  local o = cfg.orchestrator
  if type(o) ~= "table" then
    return nil, "orchestrator settings table required"
  end
  if o.uid_bits ~= 8 and o.uid_bits ~= 16 then
    return nil, "orchestrator.uid_bits must be 8 or 16"
  end
  local uid_max = (2 ^ o.uid_bits) - 1
  if type(o.uid_min) ~= "number" or o.uid_min < 1 or o.uid_min > uid_max then
    return nil, "orchestrator.uid_min out of range for uid_bits"
  end

  local baselines = cfg.recipe_baselines
  if type(baselines) ~= "table" or next(baselines) == nil then
    return nil, "recipe_baselines must be a non-empty table"
  end

  local seen_uid = {}
  for key, rule in pairs(baselines) do
    if type(rule) ~= "table" then
      return nil, "recipe_baselines[" .. tostring(key) .. "] must be a table"
    end
    if type(rule.fluid_requirement) ~= "number" or rule.fluid_requirement <= 0 then
      return nil, "recipe_baselines[" .. tostring(key) .. "] needs positive fluid_requirement"
    end
    if not rule.fluid_label then
      return nil, "recipe_baselines[" .. tostring(key) .. "] needs fluid_label"
    end
    local uid = rule.recipe_uid
    if uid ~= nil then
      if type(uid) ~= "number" or uid < 1 or uid > uid_max then
        return nil, "recipe_baselines[" .. tostring(key) .. "] recipe_uid out of range"
      end
      if seen_uid[uid] then
        return nil, "duplicate recipe_uid " .. tostring(uid) .. " on " .. tostring(key)
      end
      seen_uid[uid] = true
    end
  end

  return true
end

return Config
