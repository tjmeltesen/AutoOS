--[[
  AutoOS — Subnet Broker Config (Array Watch topology)

  AE2 handles bulk item/fluid delivery into machine inputs. Broker logic only:
    * polls gt_machine health
    * disables faulted lanes
    * recovers circuits from item bus to ME interface on completion

  Recovery interface modes:
    * per_lane (default): machines[].interface_address
    * shared: Config.shared_interface_address for all lanes
]]

local Config = {}

Config.subnet_id = "universal_chemical_mv_01"
Config.main_net_channel = 105

Config.circuit_item_name = "gregtech:gt.integrated_circuit"
Config.tick_interval = 1.0
Config.interface_mode = "per_lane" -- "per_lane" | "shared"
Config.shared_interface_address = nil -- required when interface_mode == "shared"
Config.recover_clear_interface = true

-- Phase 3: orchestrator OC modem address for SUBNET_DELIVERY / BROKER_STATUS
Config.orchestrator_address = "3bd12f6b-b5d6-4d0d-ad56-e1d372fdb4ac"
Config.broker_modem_port = 106

-- Empty OC database on the cable — descriptors allocated at runtime by
-- descriptor_cache.lua (cache hit/miss + LRU scan). No manual GUI setup.
Config.database_address = "9c22064e-7ddc-4d9a-a6a5-b732d1cba18a"

-- Slots 1..N scanned for empty / matching descriptors; broker-owned slots are
-- LRU-evicted when full. Match your OC database tier (T1=9, T2=25, T3=81).
Config.database_slot_count = 9

-- Exactly 4 lanes. Edit UUIDs in-game via: for a, n in component.list() do print(n, a) end
Config.machines = {
  {
    id = "machine_01",
    gt_address = "972c1b95-2f92-4ba2-8524-1b3152f60dfd",
    interface_address = "8c83d46a-c787-49c0-b0f1-e7447f47f95a",
    transposer_address = "58d6b8e5-b3d4-4062-9c51-2064b25e0b9e",
    interface_item_side = 1,
    item_bus_side = 0,
    interface_item_slot = 1,
    input_slot = 1,
  },
  {
    id = "machine_02",
    gt_address = "73d06674-1dbd-4c71-97be-0f958ccea03f",
    interface_address = "ca372808-6c3a-4023-a2ed-fa987ee8cd7e",
    transposer_address = "b311b7c4-cb6a-438d-b2ae-98ebdd3cf9d2",
    interface_item_side = 1,
    item_bus_side = 0,
    interface_item_slot = 1,
    input_slot = 1,
  },
  {
    id = "machine_03",
    gt_address = "61351d4f-0a11-4066-b1b9-eb1fe9393ce8",
    interface_address = "297739c6-cf5c-4442-8da9-b12e24f12233",
    transposer_address = "a1250086-ec9b-4ecd-87d3-587add148e27",
    interface_item_side = 1,
    item_bus_side = 0,
    interface_item_slot = 1,
    input_slot = 1,
  },
  {
    id = "machine_04",
    gt_address = "194191a4-1c59-4216-b49e-97268de0b600",
    interface_address = "35df79f3-b65f-4efa-a133-bf382a343c4a",
    transposer_address = "fb4d836c-b0c4-433e-a790-fed03addab7d",
    interface_item_side = 1,
    item_bus_side = 0,
    interface_item_slot = 1,
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
  local mode = cfg.interface_mode or "per_lane"

  if type(cfg.machines) ~= "table" or #cfg.machines == 0 then
    return nil, "machines must be a non-empty array"
  end
  if mode ~= "per_lane" and mode ~= "shared" then
    return nil, "interface_mode must be 'per_lane' or 'shared'"
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
      return nil, "machines[" .. i .. "] missing required field: interface_address (per_lane mode)"
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
