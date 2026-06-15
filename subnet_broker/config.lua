--[[
  AutoOS — Subnet Broker Config (1:1:1 lane topology)

  Each multiblock has its own ME Interface + Transposer + gt_machine adapter.
  Bulk crafts land in subnet ME storage; the broker pulls exact quantized
  amounts per lane via interface stocking + transposer transfer.

  Side conventions (see lane_sides.lua):
    interface_item_side / item_bus_side / fluid_pull_side / fluid_push_side
      are TRANSPOSER faces (0=bottom 1=top 2=back 3=front 4=right 5=left).
    interface_fluid_side is an ME INTERFACE block face (interface above the
      transposer → its bottom face = 0).

  References: README.md §1 Architecture Revision Addendum
]]

local Config = {}

Config.subnet_id = "universal_chemical_mv_01"
Config.main_net_channel = 105

-- Subnet ME controller/interface UUID — broker watches this for delivery deltas.
-- In-game: for a,n in component.list() do if n:find("^me_") then print(n,a) end end
-- Use the subnet ME controller (preferred) or any ME interface on the subnet cable.
Config.subnet_me_address = "7a470dd2-e0b5-4133-865a-fbc72066074a"

Config.token_item_name = "gregtech:gt.integrated_circuit"
Config.circuit_item_name = "gregtech:gt.integrated_circuit"
Config.tick_interval = 1.0

-- AE pattern scan (filtered getCraftables — not every tick)
Config.pattern_scan_enabled = true
Config.pattern_scan_interval_s = 600
Config.pattern_scan_full = false
Config.pattern_scan_extra_labels = {}
Config.uid_bits = 16
Config.uid_min = 256
Config.registry_persist = true
Config.registry_path = "/home/subnet_broker/recipe_registry.lua"
Config.default_fluid_requirement = 1000

-- Phase 3: orchestrator OC modem address for SUBNET_DELIVERY / BROKER_STATUS
Config.orchestrator_address = "3bd12f6b-b5d6-4d0d-ad56-e1d372fdb4ac"
Config.broker_modem_port = 106

-- Empty OC database on the cable — descriptors allocated at runtime by
-- descriptor_cache.lua (cache hit/miss + LRU scan). No manual GUI setup.
Config.database_address = "9c22064e-7ddc-4d9a-a6a5-b732d1cba18a"

-- Slots 1..N scanned for empty / matching descriptors; broker-owned slots are
-- LRU-evicted when full. Match your OC database tier (T1=9, T2=25, T3=81).
Config.database_slot_count = 9

Config.circuit_item_name = "gregtech:gt.integrated_circuit"

-- Exactly 4 lanes. Edit UUIDs in-game via: for a, n in component.list() do print(n, a) end
Config.machines = {
  {
    id = "machine_01",
    gt_address = "972c1b95-2f92-4ba2-8524-1b3152f60dfd",
    interface_address = "8c83d46a-c787-49c0-b0f1-e7447f47f95a",
    transposer_address = "58d6b8e5-b3d4-4062-9c51-2064b25e0b9e",
    interface_item_side = 1,
    item_bus_side = 0,
    fluid_pull_side = 1,
    fluid_push_side = 2,
    interface_fluid_side = 0,
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
    fluid_pull_side = 1,
    fluid_push_side = 2,
    interface_fluid_side = 0,
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
    fluid_pull_side = 1,
    fluid_push_side = 2,
    interface_fluid_side = 0,
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
    fluid_pull_side = 1,
    fluid_push_side = 2,
    interface_fluid_side = 0,
    interface_item_slot = 1,
    input_slot = 1,
  },
}

Config.constraints = {
  max_energy_tier = 2,
  recipe_baselines = {
    ["molten_soldering_alloy"] = {
      recipe_uid = 256,
      fluid_requirement = 1440,
      fluid_label = "Molten Soldering Alloy",
      circuit_damage = 14,
      kind = "fluid",
    },
    ["polyethylene"] = {
      recipe_uid = 257,
      display_name = "Polyethylene",
      fluid_requirement = 1000,
      fluid_label = "Ethylene",
      circuit_damage = 18,
      default_dispatch_mB = 3000,
      kind = "fluid",
    },
  },
}

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
    for _, side_field in ipairs({
      "interface_item_side", "item_bus_side",
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

  if not cfg.database_address or cfg.database_address == "" then
    return nil, "database_address required for ME interface stocking"
  end

  if not cfg.subnet_me_address or cfg.subnet_me_address == "" then
    return nil, "subnet_me_address required — subnet ME UUID for delivery watch"
  end

  if cfg.database_slot_count ~= nil
    and (type(cfg.database_slot_count) ~= "number" or cfg.database_slot_count < 1) then
    return nil, "database_slot_count must be a positive integer"
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
    if not rule.fluid_label and not rule.fluid_registry and not rule.fluid_filter then
      return nil, "recipe_baselines[" .. tostring(key) .. "] needs fluid_label, fluid_registry, or fluid_filter"
    end
  end

  return true
end

return Config
