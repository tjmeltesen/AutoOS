--[[
  AutoOS — Subnet Broker Config (LCR per-lane + dual transposer)

  v1: per_lane input, completion_mode=both, item + fluid transposer per lane.
  LCR reference: references/LCR Universal Automation.lua
]]

local Config = {}

Config.subnet_id = "universal_chemical_mv_01"
Config.main_net_channel = 105

Config.input_mode = "per_lane"
Config.completion_mode = "both"
Config.do_round_robin = true
Config.circuit_item_name = "gregtech:gt.integrated_circuit"
Config.chest_slot_start = 1
Config.circuit_bus_slot = 1
Config.settle_s = 0.1
Config.tick_interval = 1.0
Config.monitor_poll_s = 0.15
Config.staging_timeout_s = 60.0

Config.orchestrator_address = "3bd12f6b-b5d6-4d0d-ad56-e1d372fdb4ac"
Config.broker_modem_port = 106

Config.machines = {
  {
    id = "machine_01",
    gt_address = "f2b57d70-8bb4-48b7-8895-e510b1e24bca",
    item_transposer_address = "c531d5a8-c65d-471d-9057-00bf235404cf",
    fluid_transposer_address = "a4e34900-8fb9-4bf5-bcd7-3b59956d8791", -- replace with fluid hatch transposer UUID
    side_buffer = 1,
    side_bus_b = 4,
    side_return = 1,
    side_fluid_buffer = 1,
    side_fluid_hatch = 4,
    buffer_adapter_address = "b5f4d947-98a5-44b4-97d5-6720cbd25815",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
  {
    id = "machine_02",
    gt_address = "a02bf5f8-d20d-49e4-a7fb-108bcb0d268f",
    item_transposer_address = "d9df7f7f-e157-44c8-8584-2e92f142ea81",
    fluid_transposer_address = "a7e5a12e-4954-4652-8aac-e2a2a530f10a",
    side_buffer = 1,
    side_bus_b = 5,
    side_return = 1,
    side_fluid_buffer = 1,
    side_fluid_hatch = 5,
    buffer_adapter_address = "941388e1-98ad-4b4a-a4f1-a49749e13a6f",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
  {
    id = "machine_03",
    gt_address = "c2fa59cd-8e01-41f0-ae37-2a0bae0d6c9b",
    item_transposer_address = "18dd04a6-1f7f-4df5-a2b4-3191768d9c6d",
    fluid_transposer_address = "95a54203-571b-44e9-a6af-7bf3baf68c59",
    side_buffer = 1,
    side_bus_b = 4,
    side_return = 1,
    side_fluid_buffer = 1,
    side_fluid_hatch = 4,
    buffer_adapter_address = "5182a7e3-6458-41d2-8015-5bfadb91bf71",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
  {
    id = "machine_04",
    gt_address = "2a7ae941-bfec-4b8d-a4a9-58aa2bab898c",
    item_transposer_address = "de4705f9-faae-4ce0-bbaf-74d9cd5f382d",
    fluid_transposer_address = "757c0960-4e29-47f0-95a0-cdc31ea2751b",
    side_buffer = 1,
    side_bus_b = 4,
    side_return = 1,
    side_fluid_buffer = 1,
    side_fluid_hatch = 4,
    buffer_adapter_address = "db25807f-851c-4b3c-a2e5-00a245f2e23b",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
}

local REQUIRED_MACHINE_FIELDS = {
  "id",
  "gt_address",
  "item_transposer_address",
  "fluid_transposer_address",
  "side_buffer",
  "side_bus_b",
  "side_fluid_hatch",
}

local SIDE_FIELDS = {
  "side_buffer", "side_bus_b", "side_return",
  "side_fluid_buffer", "side_fluid_hatch",
  "buffer_adapter_side",
}

--- Normalize legacy transposer_address -> item_transposer_address.
local function normalize_machine(m)
  if (not m.item_transposer_address or m.item_transposer_address == "")
    and m.transposer_address and m.transposer_address ~= "" then
    m.item_transposer_address = m.transposer_address
  end
end

---@param cfg table|nil
---@return boolean|nil ok
---@return string|nil err
function Config.validate(cfg)
  cfg = cfg or Config

  if cfg.input_mode ~= nil and cfg.input_mode ~= "per_lane" then
    return nil, "v1 only supports input_mode='per_lane'"
  end
  if cfg.completion_mode ~= nil
    and cfg.completion_mode ~= "both"
    and cfg.completion_mode ~= "adapter"
    and cfg.completion_mode ~= "drain" then
    return nil, "completion_mode must be 'both', 'adapter', or 'drain'"
  end

  if type(cfg.machines) ~= "table" or #cfg.machines == 0 then
    return nil, "machines must be a non-empty array"
  end

  local seen = {}
  for i, m in ipairs(cfg.machines) do
    if type(m) ~= "table" then
      return nil, "machines[" .. i .. "] must be a table"
    end
    normalize_machine(m)
    for _, field in ipairs(REQUIRED_MACHINE_FIELDS) do
      if m[field] == nil or m[field] == "" then
        return nil, "machines[" .. i .. "] missing required field: " .. field
      end
    end
    if m.fluid_transposer_address:find("SET_FLUID", 1, true) then
      return nil, "machines[" .. i .. "] fluid_transposer_address is placeholder — set real UUID"
    end
    if m.buffer_adapter_address ~= nil and m.buffer_adapter_address ~= ""
      and m.buffer_adapter_side == nil then
      return nil, "machines[" .. i .. "] buffer_adapter_side required when buffer_adapter_address is set"
    end
    for _, side_field in ipairs(SIDE_FIELDS) do
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

  if cfg.monitor_poll_s ~= nil
    and (type(cfg.monitor_poll_s) ~= "number" or cfg.monitor_poll_s <= 0) then
    return nil, "monitor_poll_s must be a positive number"
  end
  if cfg.staging_timeout_s ~= nil
    and (type(cfg.staging_timeout_s) ~= "number" or cfg.staging_timeout_s <= 0) then
    return nil, "staging_timeout_s must be a positive number"
  end
  if cfg.settle_s ~= nil and (type(cfg.settle_s) ~= "number" or cfg.settle_s < 0) then
    return nil, "settle_s must be a non-negative number"
  end

  return true
end

return Config
