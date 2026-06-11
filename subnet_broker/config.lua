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
  { id = "reactor_01", gt_address = "gt-uuid-01", bus_in = "bus-in-01", hatch_fluid = "hatch-fluid-01" },
  { id = "reactor_02", gt_address = "gt-uuid-02", bus_in = "bus-in-02", hatch_fluid = "hatch-fluid-02" },
  { id = "reactor_03", gt_address = "gt-uuid-03", bus_in = "bus-in-03", hatch_fluid = "hatch-fluid-03" },
  { id = "reactor_04", gt_address = "gt-uuid-04", bus_in = "bus-in-04", hatch_fluid = "hatch-fluid-04" },
}

Config.constraints = {
  max_energy_tier = 2,
  recipe_baselines = {
    ["molten_soldering_alloy"] = { fluid_requirement = 1440 },
    ["polyethylene"] = { fluid_requirement = 1000 },
  },
}

return Config
