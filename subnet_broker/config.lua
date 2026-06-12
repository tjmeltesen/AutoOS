--[[

  AutoOS — Subnet Broker Config (1:1:1 lane topology)



  Each multiblock has its own ME Interface + Transposer + gt_machine adapter.

  Bulk crafts land in subnet ME storage; broker pulls exact quantized amounts

  per lane via setFluidInterfaceConfiguration / transposer transfer.



  References: README.md §1 Architecture Revision Addendum

]]



local Config = {}



-- interface_item_side = transposer face touching ME Interface (often 0 = bottom)
-- item_bus_side = transposer face touching GT item input bus / pipe
-- fluid_pull_side / fluid_push_side = fluid hatch (separate faces)
local REQUIRED_MACHINE_FIELDS = {

  "id",

  "gt_address",

  "interface_address",

  "transposer_address",

  "item_bus_side",

  "fluid_push_side",

}



---@param cfg table|nil

---@return boolean|nil ok

---@return string|nil err

function Config.validate(cfg)

  cfg = cfg or Config



  if type(cfg.machines) ~= "table" or #cfg.machines == 0 then

    return nil, "machines must be a non-empty array"

  end



  local seen = {}

  for i, m in ipairs(cfg.machines) do

    if type(m) ~= "table" then

      return nil, "machines[" .. i .. "] must be a table"

    end

    for _, field in ipairs(REQUIRED_MACHINE_FIELDS) do

      if m[field] == nil or m[field] == "" then

        return nil, "machines[" .. i .. "] missing required field: " .. field

      end

    end

    if type(m.item_bus_side) ~= "number" then

      return nil, "machines[" .. i .. "] item_bus_side must be an integer"

    end

    if type(m.fluid_push_side) ~= "number" then

      return nil, "machines[" .. i .. "] fluid_push_side must be an integer"

    end

    if m.fluid_pull_side ~= nil and type(m.fluid_pull_side) ~= "number" then

      return nil, "machines[" .. i .. "] fluid_pull_side must be an integer when set"

    end

    if seen[m.id] then

      return nil, "duplicate machine id: " .. tostring(m.id)

    end

    seen[m.id] = true

  end



  if not cfg.database_address or cfg.database_address == "" then

    return nil, "database_address required for ME interface stocking"

  end



  local baselines = cfg.constraints and cfg.constraints.recipe_baselines

  if type(baselines) ~= "table" then

    return nil, "constraints.recipe_baselines must be a table"

  end



  for key, rule in pairs(baselines) do

    if type(rule) ~= "table" then

      return nil, "recipe_baselines[" .. tostring(key) .. "] must be a table"

    end

    local req = rule.fluid_requirement

    if type(req) ~= "number" or req <= 0 then

      return nil, "recipe_baselines[" .. tostring(key) .. "] needs positive fluid_requirement"

    end

    if not rule.fluid_label and not rule.fluid_registry and not rule.fluid_filter and not rule.fluid_db_slot then

      return nil, "recipe_baselines[" .. tostring(key) .. "] needs fluid_label, fluid_registry, or fluid_filter"

    end

  end



  return true

end



Config.subnet_id = "universal_chemical_mv_01"

Config.main_net_channel = 105



-- Empty OC database on the cable — scratch slots filled at runtime from subnet ME (descriptor_cache.lua).
Config.database_address = "bcacb1a7-ebe4-48e8-940c-d436545310c7"

-- Reused scratch slots each lane cycle (no manual DB GUI setup).
Config.descriptor_scratch = {
  circuit_slot = 1,
  fluid_slot = 2,
}

-- Optional recipe key → circuit config when not on recipe_baselines.circuit_damage.
Config.recipe_circuit_damage = {
  ["molten_soldering_alloy"] = 14,
  ["polyethylene"] = 18,
}

Config.circuit_item_name = "gregtech:gt.integrated_circuit"



-- Exactly 4 lanes (edit UUIDs in-game via component.list()).

Config.machines = {

  {

    id = "machine_01",

    gt_address = "972c1b95-2f92-4ba2-8524-1b3152f60dfd",

    interface_address = "8c83d46a-c787-49c0-b0f1-e7447f47f95a",

    transposer_address = "58d6b8e5-b3d4-4062-9c51-2064b25e0b9e",

    interface_item_side = 1,

    item_bus_side = 0,

    fluid_pull_side = 2,

    fluid_push_side = 2,

    interface_fluid_side = 1,
    interface_item_slot = 1,
    input_slot = 0,

  },

  {

    id = "machine_02",

    gt_address = "73d06674-1dbd-4c71-97be-0f958ccea03f",

    interface_address = "ca372808-6c3a-4023-a2ed-fa987ee8cd7e",

    transposer_address = "b311b7c4-cb6a-438d-b2ae-98ebdd3cf9d2",

    interface_item_side = 1,

    item_bus_side = 0,

    fluid_pull_side = 2,

    fluid_push_side = 2,

    interface_fluid_side = 1,
    interface_item_slot = 1,
    input_slot = 0,

  },

  {

    id = "machine_03",

    gt_address = "61351d4f-0a11-4066-b1b9-eb1fe9393ce8",

    interface_address = "297739c6-cf5c-4442-8da9-b12e24f12233",

    transposer_address = "a1250086-ec9b-4ecd-87d3-587add148e27",

    interface_item_side = 1,

    item_bus_side = 0,

    fluid_pull_side = 2,

    fluid_push_side = 2,

    interface_fluid_side = 1,
    interface_item_slot = 1,
    input_slot = 0,

  },

  {

    id = "machine_04",

    gt_address = "194191a4-1c59-4216-b49e-97268de0b600",

    interface_address = "35df79f3-b65f-4efa-a133-bf382a343c4a",

    transposer_address = "fb4d836c-b0c4-433e-a790-fed03addab7d",

    interface_item_side = 1,

    item_bus_side = 0,

    fluid_pull_side = 2,

    fluid_push_side = 2,

    interface_fluid_side = 1,
    interface_item_slot = 1,
    input_slot = 0,

  },

}



Config.constraints = {

  max_energy_tier = 2,

  recipe_baselines = {

    ["molten_soldering_alloy"] = {

      fluid_requirement = 1440,

      fluid_label = "Molten Soldering Alloy",

      circuit_damage = 14,

      kind = "fluid",

    },

    ["polyethylene"] = {

      fluid_requirement = 1000,

      fluid_label = "Ethylene",

      circuit_damage = 18,

      kind = "fluid",

    },

  },

}



return Config

