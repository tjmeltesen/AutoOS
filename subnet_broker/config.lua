--[[
  AutoOS — Subnet Broker Config (Array Watch topology)

  AE2 handles bulk item/fluid delivery into machine inputs. Broker logic only:
    * polls gt_machine health
    * disables faulted lanes
    * recovers circuits via transposer when processing completes

  Recovery is transposer-only by default:
    transferItem(item_bus_side → recover_side) onto the ME interface block face.
    No OC me_interface adapter required — ME import absorbs the item in-world.

  Optional interface_mode (legacy / special wiring only):
    * transposer (default) — no interface_address in config
    * per_lane / shared — set interface_address or shared_interface_address only
      if you also have an OC adapter and want setInterfaceConfiguration clear
]]

local Config = {}

Config.subnet_id = "universal_chemical_mv_01"
Config.main_net_channel = 105

Config.circuit_item_name = "gregtech:gt.integrated_circuit"
Config.tick_interval = 1.0
Config.interface_mode = "transposer" -- "transposer" | "per_lane" | "shared"
Config.shared_interface_address = nil -- only when interface_mode == "shared"
Config.recover_clear_interface = true -- only used when an OC me_interface address is set

Config.orchestrator_address = "3bd12f6b-b5d6-4d0d-ad56-e1d372fdb4ac"
Config.broker_modem_port = 106

-- Optional — legacy demoted dispatch / push_circuit only
Config.database_address = "9c22064e-7ddc-4d9a-a6a5-b732d1cba18a"
Config.database_slot_count = 9

-- Per lane: gt_machine + transposer + sides. No interface_address needed for watch mode.
Config.machines = {
  {
    id = "machine_01",
    gt_address = "972c1b95-2f92-4ba2-8524-1b3152f60dfd",
    transposer_address = "7ff4353b-1cad-43a1-89cb-0a6cd2aab9cb",
    recover_side = 1,       -- transposer face touching ME interface (import)
    item_bus_side = 2,      -- transposer face touching GT input bus
    recover_slot = 1,
    input_slot = 1,
  },
  {
    id = "machine_02",
    gt_address = "73d06674-1dbd-4c71-97be-0f958ccea03f",
    transposer_address = "1954897b-991a-4942-a251-59e16bad0ab7",
    recover_side = 1,
    item_bus_side = 2,
    recover_slot = 1,
    input_slot = 1,
  },
  {
    id = "machine_03",
    gt_address = "61351d4f-0a11-4066-b1b9-eb1fe9393ce8",
    transposer_address = "7eee9782-5de9-41cf-8422-222da9bcb06e",
    recover_side = 1,
    item_bus_side = 2,
    recover_slot = 1,
    input_slot = 1,
  },
  {
    id = "machine_04",
    gt_address = "194191a4-1c59-4216-b49e-97268de0b600",
    transposer_address = "aaeb795a-8059-46ac-9835-0398027cd248",
    recover_side = 1,
    item_bus_side = 2,
    recover_slot = 1,
    input_slot = 1,
  },
}

-- Optional legacy dispatch settings (manual tests only).
Config.constraints = Config.constraints or {
  recipe_baselines = {
    molten_soldering_alloy = {
      fluid_requirement = 1440,
      fluid_label = "Molten Soldering Alloy",
      kind = "fluid",
      circuit_damage = 14,
    },
    polyethylene = {
      fluid_requirement = 1000,
      fluid_label = "Ethylene",
      kind = "fluid",
      circuit_damage = 18,
    },
  },
}

local REQUIRED_MACHINE_FIELDS = {
  "id",
  "gt_address",
  "transposer_address",
  "item_bus_side",
}

---@param cfg table|nil
---@return boolean|nil ok
---@return string|nil err
function Config.validate(cfg)
  cfg = cfg or Config
  local mode = cfg.interface_mode or "transposer"

  if type(cfg.machines) ~= "table" or #cfg.machines == 0 then
    return nil, "machines must be a non-empty array"
  end
  if mode ~= "transposer" and mode ~= "per_lane" and mode ~= "shared" then
    return nil, "interface_mode must be 'transposer', 'per_lane', or 'shared'"
  end
  if mode == "shared" and (cfg.shared_interface_address == nil or cfg.shared_interface_address == "") then
    return nil, "shared_interface_address required when interface_mode='shared'"
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
    if mode == "per_lane" and (m.interface_address == nil or m.interface_address == "") then
      return nil, "machines[" .. i .. "] missing interface_address (interface_mode='per_lane')"
    end
    for _, side_field in ipairs({
      "interface_item_side", "recover_side", "item_bus_side",
      "fluid_pull_side", "fluid_push_side", "interface_fluid_side",
    }) do
      local v = m[side_field]
      if v ~= nil and (type(v) ~= "number" or v < 0 or v > 5) then
        return nil, "machines[" .. i .. "] " .. side_field .. " must be a side integer 0-5"
      end
    end
    if seen[m.id] then
      return nil, "duplicate machine id: " .. tostring(m.id)
    end
    seen[m.id] = true
  end

  if cfg.database_slot_count ~= nil
    and (type(cfg.database_slot_count) ~= "number" or cfg.database_slot_count < 1) then
    return nil, "database_slot_count must be a positive integer"
  end

  return true
end

return Config
