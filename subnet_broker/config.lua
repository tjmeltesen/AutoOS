--[[
  AutoOS — Subnet Broker Config (LCR dual transposer)

  input_mode:
    per_lane — AE deposits to each lane buffer (LCR reference)
    central  — AE deposits to shared buffer; RR dispatch to next available machine
]]

local Config = {}

Config.subnet_id = "universal_chemical_mv_01"
Config.main_net_channel = 105

Config.input_mode = "central"
Config.completion_mode = "both"
Config.do_round_robin = true
Config.circuit_item_name = "gregtech:gt.integrated_circuit"
Config.chest_slot_start = 1
Config.circuit_bus_slot = 1
Config.settle_s = 0.1
Config.tick_interval = 1.0
Config.monitor_poll_s = 0.15
Config.staging_timeout_s = 60.0
Config.require_empty_return = true

Config.orchestrator_address = "3bd12f6b-b5d6-4d0d-ad56-e1d372fdb4ac"
Config.broker_modem_port = 106

-- Shared AE deposit (input_mode = "central" only)
Config.central = {
  item_transposer_address = "770f1b9a-323c-4a98-9110-2088a92c5b08",
  fluid_transposer_address = "caf12964-5fe2-4f82-ba00-9618afd44f62",
  side_buffer = 5,
  chest_slot_start = 1,
  max_circuits_in_buffer = 1,
  buffer_adapter_address = nil,
  buffer_adapter_side = 0,
}

Config.machines = {
  {
    id = "machine_01",
    gt_address = "ed859452-2cd0-48bf-85cc-7bc3bca4f29d",
    item_transposer_address = "c531d5a8-c65d-471d-9057-00bf235404cf",
    fluid_transposer_address = "a4e34900-8fb9-4bf5-bcd7-3b59956d8791",
    central_item_side = 0,
    central_fluid_side = 0,
    side_buffer = 2,
    side_bus_b = 0,
    side_return = 4,
    side_fluid_buffer = 2,
    side_fluid_hatch = 0,
    buffer_adapter_address = "b5f4d947-98a5-44b4-97d5-6720cbd25815",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
  {
    id = "machine_02",
    gt_address = "b1a8e372-7aaf-4d9b-b1f8-eed37a7e678d",
    item_transposer_address = "d9df7f7f-e157-44c8-8584-2e92f142ea81",
    fluid_transposer_address = "a7e5a12e-4954-4652-8aac-e2a2a530f10a",
    central_item_side = 1,
    central_fluid_side = 1,
    side_buffer = 2,
    side_bus_b = 0,
    side_return = 5,
    side_fluid_buffer = 2,
    side_fluid_hatch = 0,
    buffer_adapter_address = "941388e1-98ad-4b4a-a4f1-a49749e13a6f",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
  {
    id = "machine_03",
    gt_address = "d0713001-d339-4272-a7cf-cce61c2360d0",
    item_transposer_address = "18dd04a6-1f7f-4df5-a2b4-3191768d9c6d",
    fluid_transposer_address = "95a54203-571b-44e9-a6af-7bf3baf68c59",
    central_item_side = 3,
    central_fluid_side = 3,
    side_buffer = 2,
    side_bus_b = 0,
    side_return = 4,
    side_fluid_buffer = 2,
    side_fluid_hatch = 0,
    buffer_adapter_address = "5182a7e3-6458-41d2-8015-5bfadb91bf71",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
  {
    id = "machine_04",
    gt_address = "a4bd12cb-8d12-4d86-86db-131dbd5cd076",
    item_transposer_address = "de4705f9-faae-4ce0-bbaf-74d9cd5f382d",
    fluid_transposer_address = "757c0960-4e29-47f0-95a0-cdc31ea2751b",
    central_item_side = 4,
    central_fluid_side = 4,
    side_buffer = 2,
    side_bus_b = 0,
    side_return = 5,
    side_fluid_buffer = 2,
    side_fluid_hatch = 0,
    buffer_adapter_address = "db25807f-851c-4b3c-a2e5-00a245f2e23b",
    buffer_adapter_side = 0,
    input_slot = 1,
  },
}

local PER_LANE_REQUIRED = {
  "id", "gt_address", "item_transposer_address", "fluid_transposer_address",
  "side_buffer", "side_bus_b", "side_fluid_hatch",
}

local CENTRAL_MACHINE_REQUIRED = {
  "id", "gt_address", "item_transposer_address", "fluid_transposer_address",
  "side_bus_b", "side_fluid_hatch", "central_item_side", "central_fluid_side",
}

local SIDE_FIELDS = {
  "side_buffer", "side_bus_b", "side_return",
  "side_fluid_buffer", "side_fluid_hatch",
  "buffer_adapter_side", "central_item_side", "central_fluid_side",
}

local function normalize_machine(m)
  if (not m.item_transposer_address or m.item_transposer_address == "")
    and m.transposer_address and m.transposer_address ~= "" then
    m.item_transposer_address = m.transposer_address
  end
end

local function validate_side_fields(cfg, i, m)
  for _, side_field in ipairs(SIDE_FIELDS) do
    local v = m[side_field]
    if v ~= nil and (type(v) ~= "number" or v < 0 or v > 5) then
      return nil, "machines[" .. i .. "] " .. side_field .. " must be a side integer 0-5"
    end
  end
  return true
end

---@param cfg table|nil
---@return boolean|nil ok
---@return string|nil err
function Config.validate(cfg)
  cfg = cfg or Config

  local input_mode = cfg.input_mode or "per_lane"
  if input_mode ~= "per_lane" and input_mode ~= "central" then
    return nil, "input_mode must be 'per_lane' or 'central'"
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

  if input_mode == "central" then
    local c = cfg.central
    if type(c) ~= "table" then
      return nil, "input_mode=central requires Config.central table"
    end
    if not c.item_transposer_address or c.item_transposer_address == ""
      or c.item_transposer_address:find("SET_CENTRAL", 1, true) then
      return nil, "central.item_transposer_address must be set"
    end
    if not c.fluid_transposer_address or c.fluid_transposer_address == ""
      or c.fluid_transposer_address:find("SET_CENTRAL", 1, true) then
      return nil, "central.fluid_transposer_address must be set"
    end
    if type(c.side_buffer) ~= "number" or c.side_buffer < 0 or c.side_buffer > 5 then
      return nil, "central.side_buffer must be a side integer 0-5"
    end
    local max_circ = c.max_circuits_in_buffer
    if max_circ ~= nil and (type(max_circ) ~= "number" or max_circ < 1) then
      return nil, "central.max_circuits_in_buffer must be a positive integer"
    end
    if c.buffer_adapter_address ~= nil and c.buffer_adapter_address ~= ""
      and c.buffer_adapter_side == nil then
      return nil, "central.buffer_adapter_side required when buffer_adapter_address is set"
    end
  end

  local required = input_mode == "central" and CENTRAL_MACHINE_REQUIRED or PER_LANE_REQUIRED
  local seen = {}
  for i, m in ipairs(cfg.machines) do
    if type(m) ~= "table" then
      return nil, "machines[" .. i .. "] must be a table"
    end
    normalize_machine(m)
    for _, field in ipairs(required) do
      if m[field] == nil or m[field] == "" then
        return nil, "machines[" .. i .. "] missing required field: " .. field
      end
    end
    if m.fluid_transposer_address:find("SET_FLUID", 1, true) then
      return nil, "machines[" .. i .. "] fluid_transposer_address is placeholder — set real UUID"
    end
    if input_mode == "per_lane" then
      if m.buffer_adapter_address ~= nil and m.buffer_adapter_address ~= ""
        and m.buffer_adapter_side == nil then
        return nil, "machines[" .. i .. "] buffer_adapter_side required when buffer_adapter_address is set"
      end
    end
    local ok_side, side_err = validate_side_fields(cfg, i, m)
    if not ok_side then return nil, side_err end
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
