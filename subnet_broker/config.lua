--[[
  AutoOS — Subnet Broker Config (Array Watch topology)

  AE2 handles bulk item/fluid delivery into machine inputs. Broker logic only:
    * polls gt_machine health
    * disables faulted lanes
    * recovers circuits via transposer when processing completes

  Circuit flow (watch mode):
    side_buffer -> side_bus_b -> side_return (default side_buffer).
    Activity comes from gt_machine.isMachineActive() via adapter polling.

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
Config.monitor_poll_s = 0.15
Config.staging_timeout_s = 3.0
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
    transposer_address = "06f8b305-6aed-464b-901c-5f63c891e131",
    side_buffer = 1,        -- transposer face touching super-buffer / chest
    side_bus_b = 4,         -- transposer face touching GT circuit input bus
    side_return = 1,        -- optional; default is side_buffer
    return_slot = nil,      -- optional destination slot on return side
    buffer_adapter_address = "b5f4d947-98a5-44b4-97d5-6720cbd25815", -- optional adapter on buffer for low-cost item presence gate
    buffer_adapter_side = 0,    -- required when buffer_adapter_address is set (0-5)
    input_slot = 1,
  },
  {
    id = "machine_02",
    gt_address = "73d06674-1dbd-4c71-97be-0f958ccea03f",
    transposer_address = "dff356f1-ea3e-4333-872a-dc10af3eafaf",
    side_buffer = 1,
    side_bus_b = 4,
    side_return = 1,
    return_slot = nil,
    buffer_adapter_address = "941388e1-98ad-4b4a-a4f1-a49749e13a6f",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
  {
    id = "machine_03",
    gt_address = "194191a4-1c59-4216-b49e-97268de0b600",
    transposer_address = "66962f00-68ff-4d10-8151-348481a0bb6e",
    side_buffer = 1,
    side_bus_b = 4,
    side_return = 1,
    return_slot = nil,
    buffer_adapter_address = "5182a7e3-6458-41d2-8015-5bfadb91bf71",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
  {
    id = "machine_04",
    gt_address = "890321a4-b96c-43c4-a239-be3563b97eab",
    transposer_address = "8e8c359c-1a45-49b7-96bf-fe97142edce7",
    side_buffer = 1,
    side_bus_b = 4,
    side_return = 1,
    return_slot = nil,
    buffer_adapter_address = "db25807f-851c-4b3c-a2e5-00a245f2e23b",
    buffer_adapter_side = 0,
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
  "side_buffer",
  "side_bus_b",
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
    if m.buffer_adapter_address ~= nil and m.buffer_adapter_address ~= ""
      and (m.buffer_adapter_side == nil) then
      return nil, "machines[" .. i .. "] buffer_adapter_side required when buffer_adapter_address is set"
    end
    for _, side_field in ipairs({
      "side_buffer", "side_bus_b", "side_return",
      "buffer_adapter_side",
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
  if cfg.monitor_poll_s ~= nil
    and (type(cfg.monitor_poll_s) ~= "number" or cfg.monitor_poll_s <= 0) then
    return nil, "monitor_poll_s must be a positive number"
  end
  if cfg.staging_timeout_s ~= nil
    and (type(cfg.staging_timeout_s) ~= "number" or cfg.staging_timeout_s <= 0) then
    return nil, "staging_timeout_s must be a positive number"
  end

  return true
end

return Config
