--[[
  AutoOS — Subnet Broker Config (Phase 1)

  Local hardware and recipe context for one machine array. This is the only
  file that changes between physical subnet deployments.

  References: README.md §4, references/gtnh-opencomputers-overview.md
]]

local Config = {}

local REQUIRED_MACHINE_FIELDS = { "id", "gt_address", "bus_in", "hatch_fluid" }

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
Config.circuit_vault_address = "vault-chest-00a12"

Config.machines = {
  { id = "reactor_01", gt_address = "972c1b95-2f92-4ba2-8524-1b3152f60dfd", bus_in = "58d6b8e5-b3d4-4062-9c51-2064b25e0b9e", hatch_fluid = "eb9c49a7-bf26-448a-b7ff-649bc1203639" },
  { id = "reactor_02", gt_address = "73d06674-1dbd-4c71-97be-0f958ccea03f", bus_in = "b311b7c4-cb6a-438d-b2ae-98ebdd3cf9d2", hatch_fluid = "789ee6ac-20ea-4a86-8fb6-e64ecf80af47" },
  { id = "reactor_03", gt_address = "61351d4f-0a11-4066-b1b9-eb1fe9393ce8", bus_in = "a1250086-ec9b-4ecd-87d3-587add148e27", hatch_fluid = "db65fd20-cdaf-480c-a232-f82df07c0fda" },
  { id = "reactor_04", gt_address = "194191a4-1c59-4216-b49e-97268de0b600", bus_in = "fb4d836c-b0c4-433e-a790-fed03addab7d", hatch_fluid = "1403ad07-68bf-45ed-bb54-9a1650081a96" },
}

Config.constraints = {
  max_energy_tier = 2,
  recipe_baselines = {
    ["molten_soldering_alloy"] = { fluid_requirement = 1440 },
    ["polyethylene"] = { fluid_requirement = 1000 },
  },
}

return Config
