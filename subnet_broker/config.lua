--[[
  AutoOS — Subnet Broker Config (LCR dual transposer)

  input_mode:
    per_lane — AE deposits to each lane buffer (LCR reference)
    central  — AE deposits to shared chest via storage bus; adapter monitor + stabilize_s
]]

local Config = {}

Config.subnet_id = "universal_chemical_mv_01"
Config.main_net_channel = 105

Config.input_mode = "central"
Config.completion_mode = "both"
Config.do_round_robin = true
Config.circuit_item_name = "gregtech:gt.integrated_circuit"
Config.database_address = "9c22064e-7ddc-4d9a-a6a5-b732d1cba18a"
Config.database_slot_count = 9
Config.interface_item_slots = 9
Config.interface_item_slot_start = 1
Config.interface_fluid_side = 0 -- What is this for? 
Config.shared_interface_address = "" -- optional fallback if all lanes share one ME interface adapter
Config.chest_slot_start = 1
Config.circuit_bus_slot = 1
Config.settle_s = 0.1
Config.tick_interval = 1.0
Config.monitor_poll_s = 0.15
Config.staging_timeout_s = 60.0
Config.require_empty_return = true
Config.scheduler = {
  max_parallel_lanes = nil, -- nil defaults to #machines after Config.machines is loaded
  max_job_attempts = 2,
  watchdog_grace_s = 10,
  persist_jobs = "startup_sweep",
}

Config.orchestrator_address = "3bd12f6b-b5d6-4d0d-ad56-e1d372fdb4ac"
Config.broker_modem_port = 106

-- Shared AE deposit (input_mode = "central" only)
-- buffer_adapter = OC adapter on item chest (storage bus side)
-- fluid_adapter provides central tank-controller fluid manifest inputs in central mode
-- monitor: "adapter" (default) or "inventory_controller" on broker OC
-- require_interface_staging: true = reject handoff until dual IF side_buffer shows items
-- interface_wait_s: max wait after handoff for subnet items to appear on dual IF (default staging_timeout_s)
-- settle_s: central handoff settle before item/fluid tracks start polling per-lane dual IF
Config.central = {
  monitor = "inventory_controller",
  inventory_controller_side = 0,
  buffer_adapter_address = "30c39ca2-68b9-4f71-8b0d-291cd6bcdc01",
  buffer_adapter_side = 0,
  fluid_adapter_address = "9a4d0d5f-26e4-4f0e-9330-9d416433c657",
  fluid_adapter_side = 0,
  chest_slot_start = 1,
  max_circuits_in_buffer = 1,
  ingest_mode = "event_or_poll",
  job_stabilize_s = 1.0,
  stabilize_s = 1.0,
  settle_s = 0.0,
  interface_wait_s = 5.0,
  require_interface_staging = false,
}

Config.machines = {
  {
    id = "machine_01",
    gt_address = "ed859452-2cd0-48bf-85cc-7bc3bca4f29d",
    interface_address = "74e982ba-35e4-4b94-900e-0919f76e7098",
    item_transposer_address = "c531d5a8-c65d-471d-9057-00bf235404cf",
    fluid_transposer_address = "ba0b4eb2-4e17-4c2f-a0b7-4a57abd0b03d",
    side_buffer = 2,
    side_bus_b = 0,
    side_return = 4,
    side_fluid_buffer = 4,
    side_fluid_hatch = 0,
    input_slot = 1,
  },
  {
    id = "machine_02",
    gt_address = "b1a8e372-7aaf-4d9b-b1f8-eed37a7e678d",
    interface_address = "453091f9-9f78-4d07-a487-74afe5d170d2",
    item_transposer_address = "d9df7f7f-e157-44c8-8584-2e92f142ea81",
    fluid_transposer_address = "a8b18bd6-1b0d-4d61-b4fc-fd1be2077945",
    side_buffer = 2,
    side_bus_b = 0,
    side_return = 5,
    side_fluid_buffer = 5,
    side_fluid_hatch = 0,
    input_slot = 1,
  },
  {
    id = "machine_03",
    gt_address = "d0713001-d339-4272-a7cf-cce61c2360d0",
    interface_address = "32332048-d9e0-4c43-9c9d-7378e668e2cb",
    item_transposer_address = "18dd04a6-1f7f-4df5-a2b4-3191768d9c6d",
    fluid_transposer_address = "f78a9bb6-0a1f-46e2-bef2-89402e5cea18",
    side_buffer = 2,
    side_bus_b = 0,
    side_return = 4,
    side_fluid_buffer = 4,
    side_fluid_hatch = 0,
    input_slot = 1,
  },
  {
    id = "machine_04",
    gt_address = "a4bd12cb-8d12-4d86-86db-131dbd5cd076",
    interface_address = "ae1fbbba-ad3a-4a5b-b624-66c1ac11afec",
    item_transposer_address = "de4705f9-faae-4ce0-bbaf-74d9cd5f382d",
    fluid_transposer_address = "d05c4e17-c2db-4e48-b112-50f1db80b22e",
    side_buffer = 2,
    side_bus_b = 0,
    side_return = 5,
    side_fluid_buffer = 5,
    side_fluid_hatch = 0,
    input_slot = 1,
  },
}

local PER_LANE_REQUIRED = {
  "id", "gt_address", "item_transposer_address", "fluid_transposer_address",
  "side_buffer", "side_bus_b", "side_fluid_hatch",
}

local CENTRAL_MACHINE_REQUIRED = {
  "id", "gt_address", "item_transposer_address", "fluid_transposer_address",
  "side_buffer", "side_bus_b", "side_fluid_hatch", "side_return",
}

local SIDE_FIELDS = {
  "side_buffer", "side_bus_b", "side_return",
  "side_fluid_buffer", "side_fluid_hatch",
  "side_central", "side_central_fluid",
  "buffer_adapter_side", "fluid_adapter_side",
  "interface_fluid_side",
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
    local monitor = c.monitor or "adapter"
    if monitor ~= "adapter" and monitor ~= "inventory_controller" then
      return nil, "central.monitor must be 'adapter' or 'inventory_controller'"
    end
    if monitor == "adapter" then
      if not c.buffer_adapter_address or c.buffer_adapter_address == ""
        or c.buffer_adapter_address:find("SET_", 1, true) then
        return nil, "central.buffer_adapter_address must be set (item chest adapter)"
      end
      if type(c.buffer_adapter_side) ~= "number" or c.buffer_adapter_side < 0 or c.buffer_adapter_side > 5 then
        return nil, "central.buffer_adapter_side must be a side integer 0-5"
      end
    else
      if type(c.inventory_controller_side) ~= "number"
        or c.inventory_controller_side < 0 or c.inventory_controller_side > 5 then
        return nil, "central.inventory_controller_side must be 0-5 when monitor=inventory_controller"
      end
    end
    if c.fluid_adapter_address ~= nil and c.fluid_adapter_address ~= ""
      and c.fluid_adapter_side == nil then
      return nil, "central.fluid_adapter_side required when fluid_adapter_address is set"
    end
    local max_circ = c.max_circuits_in_buffer
    if max_circ ~= nil and (type(max_circ) ~= "number" or max_circ < 1) then
      return nil, "central.max_circuits_in_buffer must be a positive integer"
    end
    if c.stabilize_s ~= nil and (type(c.stabilize_s) ~= "number" or c.stabilize_s < 0) then
      return nil, "central.stabilize_s must be a non-negative number"
    end
    if c.job_stabilize_s ~= nil and (type(c.job_stabilize_s) ~= "number" or c.job_stabilize_s < 0) then
      return nil, "central.job_stabilize_s must be a non-negative number"
    end
    local ingest_mode = c.ingest_mode or "event_or_poll"
    if ingest_mode ~= "event_or_poll" and ingest_mode ~= "poll" and ingest_mode ~= "event" then
      return nil, "central.ingest_mode must be 'event_or_poll', 'event', or 'poll'"
    end
    if c.settle_s ~= nil and (type(c.settle_s) ~= "number" or c.settle_s < 0) then
      return nil, "central.settle_s must be a non-negative number"
    end
  end

  local required = input_mode == "central" and CENTRAL_MACHINE_REQUIRED or PER_LANE_REQUIRED
  local db_addr = cfg.database_address
  local stock_enabled = type(db_addr) == "string"
    and db_addr ~= ""
    and not db_addr:find("SET_", 1, true)
  if input_mode == "central" and stock_enabled then
    local c = cfg.central or {}
    if not c.fluid_adapter_address or c.fluid_adapter_address == "" then
      return nil, "central.fluid_adapter_address required in central mode when interface stocking is enabled"
    end
  end
  local shared_iface = type(cfg.shared_interface_address) == "string"
    and cfg.shared_interface_address ~= ""
    and not cfg.shared_interface_address:find("SET_", 1, true)

  if cfg.database_slot_count ~= nil
    and (type(cfg.database_slot_count) ~= "number" or cfg.database_slot_count < 1) then
    return nil, "database_slot_count must be a positive integer"
  end
  if cfg.interface_item_slots ~= nil
    and (type(cfg.interface_item_slots) ~= "number" or cfg.interface_item_slots < 1) then
    return nil, "interface_item_slots must be a positive integer"
  end
  if cfg.interface_item_slot_start ~= nil
    and (type(cfg.interface_item_slot_start) ~= "number" or cfg.interface_item_slot_start < 1) then
    return nil, "interface_item_slot_start must be a positive integer"
  end

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
    if stock_enabled
      and (not m.interface_address or m.interface_address == "")
      and not shared_iface then
      return nil, "machines[" .. i .. "] interface_address required when database_address is configured (or set shared_interface_address)"
    end
    if m.interface_item_slot_start ~= nil
      and (type(m.interface_item_slot_start) ~= "number" or m.interface_item_slot_start < 1) then
      return nil, "machines[" .. i .. "] interface_item_slot_start must be a positive integer"
    end
    if m.interface_item_slots ~= nil
      and (type(m.interface_item_slots) ~= "number" or m.interface_item_slots < 1) then
      return nil, "machines[" .. i .. "] interface_item_slots must be a positive integer"
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
  if cfg.scheduler ~= nil then
    if type(cfg.scheduler) ~= "table" then return nil, "scheduler must be a table" end
    if cfg.scheduler.max_parallel_lanes ~= nil
      and (type(cfg.scheduler.max_parallel_lanes) ~= "number" or cfg.scheduler.max_parallel_lanes < 1) then
      return nil, "scheduler.max_parallel_lanes must be a positive integer"
    end
    if cfg.scheduler.max_job_attempts ~= nil
      and (type(cfg.scheduler.max_job_attempts) ~= "number" or cfg.scheduler.max_job_attempts < 1) then
      return nil, "scheduler.max_job_attempts must be a positive integer"
    end
    if cfg.scheduler.watchdog_grace_s ~= nil
      and (type(cfg.scheduler.watchdog_grace_s) ~= "number" or cfg.scheduler.watchdog_grace_s < 0) then
      return nil, "scheduler.watchdog_grace_s must be non-negative"
    end
    local persist = cfg.scheduler.persist_jobs or "startup_sweep"
    if persist ~= "startup_sweep" and persist ~= "file" then
      return nil, "scheduler.persist_jobs must be 'startup_sweep' or 'file'"
    end
  end

  return true
end

return Config
