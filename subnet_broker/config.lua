--[[

  AutoOS — Subnet Broker Config



  Local hardware and recipe context for one machine array. This is the only

  file that changes between physical subnet deployments.



  References: README.md §4, references/gtnh-opencomputers-overview.md

]]



local Config = {}



local REQUIRED_MACHINE_FIELDS = { "id", "gt_address", "bus_in", "hatch_fluid" }



local function machine_route_mode(m)

  return m.circuit_route or "auto"

end



---@param cfg table|nil Defaults to the module table when omitted.

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

    if seen[m.id] then

      return nil, "duplicate machine id: " .. tostring(m.id)

    end

    seen[m.id] = true



    local route = machine_route_mode(m)

    if route == "export_bus" and m.bus_export_side == nil then

      return nil, "machines[" .. i .. "] circuit_route export_bus requires bus_export_side"

    end

    if route == "transposer" then

      local vault = cfg.circuit_vault and cfg.circuit_vault.address or cfg.circuit_vault_address

      if not vault or vault == "" then

        return nil, "machines[" .. i .. "] transposer route requires circuit_vault.address"

      end

      if m.transposer_vault_side == nil or m.transposer_to_bus_side == nil then

        return nil, "machines[" .. i .. "] transposer route requires transposer_vault_side and transposer_to_bus_side"

      end

    end

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

  end



  return true

end



-- Default deployment template (edit addresses in-game).

Config.subnet_id = "universal_chemical_mv_01"

Config.main_net_channel = 105



-- Vault transposer between OC and programmed-circuit chest (recover + transposer push).

Config.circuit_vault = {

  address = "vault-chest-00a12",

  component_type = "transposer",

}



-- Legacy alias (falls back when circuit_vault.address unset).

Config.circuit_vault_address = Config.circuit_vault.address



-- OC database with programmed circuit entries for ME export bus path.

Config.database_address = "database-00a12"



-- circuit_damage → database slot (for setExportConfiguration).

Config.circuit_db_slots = {

  [14] = 1,

  [18] = 2,

}



-- recipe key → integrated circuit configuration number (damage/metadata).

Config.recipe_circuit_damage = {

  ["molten_soldering_alloy"] = 14,

  ["polyethylene"] = 18,

}



Config.circuit_item_name = "gregtech:gt.integrated_circuit"



-- Per-machine routing defaults (bus_in = me_exportbus; transposer on bus for recover).

Config.machines = {

  {

    id = "reactor_01",

    gt_address = "972c1b95-2f92-4ba2-8524-1b3152f60dfd",

    bus_in = "58d6b8e5-b3d4-4062-9c51-2064b25e0b9e",

    hatch_fluid = "eb9c49a7-bf26-448a-b7ff-649bc1203639",

    bus_export_side = 3,

    circuit_route = "transposer",

    transposer_address = "2403c040-d5b4-4878-bf3c-c3b79650dbc0",

    transposer_vault_side = 2,

    transposer_to_bus_side = 3,

    gt_bus_slot = 0,

  },

  {

    id = "reactor_02",

    gt_address = "73d06674-1dbd-4c71-97be-0f958ccea03f",

    bus_in = "b311b7c4-cb6a-438d-b2ae-98ebdd3cf9d2",

    hatch_fluid = "789ee6ac-20ea-4a86-8fb6-e64ecf80af47",

    bus_export_side = 3,

    circuit_route = "transposer",

    transposer_address = "2403c040-d5b4-4878-bf3c-c3b79650dbc0",

    transposer_vault_side = 2,

    transposer_to_bus_side = 3,

    gt_bus_slot = 0,

  },

  {

    id = "reactor_03",

    gt_address = "61351d4f-0a11-4066-b1b9-eb1fe9393ce8",

    bus_in = "a1250086-ec9b-4ecd-87d3-587add148e27",

    hatch_fluid = "db65fd20-cdaf-480c-a232-f82df07c0fda",

    bus_export_side = 3,

    circuit_route = "transposer",

    transposer_address = "2403c040-d5b4-4878-bf3c-c3b79650dbc0",

    transposer_vault_side = 2,

    transposer_to_bus_side = 3,

    gt_bus_slot = 0,

  },

  {

    id = "reactor_04",

    gt_address = "194191a4-1c59-4216-b49e-97268de0b600",

    bus_in = "fb4d836c-b0c4-433e-a790-fed03addab7d",

    hatch_fluid = "1403ad07-68bf-45ed-bb54-9a1650081a96",

    bus_export_side = 3,

    circuit_route = "transposer",

    transposer_address = "2403c040-d5b4-4878-bf3c-c3b79650dbc0",

    transposer_vault_side = 2,

    transposer_to_bus_side = 3,

    gt_bus_slot = 0,

  },

}



Config.constraints = {

  max_energy_tier = 2,

  recipe_baselines = {

    ["molten_soldering_alloy"] = { fluid_requirement = 1440 },

    ["polyethylene"] = { fluid_requirement = 1000 },

  },

}



return Config

