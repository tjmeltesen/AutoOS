--[[
  AutoOS — Admission Control
  Circuit count check — suppresses job creation when too many circuits are
  in the central buffer.
]]
local AdmissionControl = {}

--- Config cascade: get max circuits threshold.
function AdmissionControl.max_circuits(config)
  local c = config.central or {}
  return c.max_circuits_in_buffer or config.max_circuits_in_buffer
end

--- Config cascade: get job stabilization timeout.
function AdmissionControl.job_stabilize_s(config)
  local c = config.central or {}
  return c.job_stabilize_s or c.stabilize_s or 3.0
end

--- Count circuits in the central chest.
--- @param registry table  cached proxies
--- @param config table    validated Config
--- @param circuit_manager table|nil  optional circuit detection module
--- @param yield_fn function|nil
--- @return number
function AdmissionControl.count_circuits(registry, config, circuit_manager, yield_fn)
  local adapter = registry.central_item_adapter
  if not adapter or not circuit_manager then return 0 end
  local side = registry.central_item_side
  if type(side) ~= "number" then return 0 end

  local n = 0
  local start = registry.chest_slot_start or config.chest_slot_start or 1
  local ok_size, size = pcall(adapter.getInventorySize, side)
  if not ok_size or type(size) ~= "number" then return 0 end

  for slot = start, size do
    if slot % 10 == 0 and yield_fn then yield_fn() end
    local ok_st, st = pcall(adapter.getStackInSlot, side, slot)
    if ok_st and circuit_manager.stack_is_circuit
      and circuit_manager:stack_is_circuit(st) then
      n = n + 1
    end
  end
  return n
end

--- Check if admission is OK (circuit count under threshold).
--- @param registry table
--- @param config table
--- @param circuit_manager table|nil
--- @param lanes table  machine_id -> lane record (for inflight deduction)
--- @param log_fn function
--- @param yield_fn function|nil
--- @param C table  constants module
--- @return boolean
function AdmissionControl.is_ok(registry, config, circuit_manager, lanes, log_fn, yield_fn, C)
  local max_circ = AdmissionControl.max_circuits(config)
  if not max_circ or max_circ < 1 then return true end

  local n = AdmissionControl.count_circuits(registry, config, circuit_manager, yield_fn)

  -- Subtract WORKING lanes (their circuits are about to be pulled by AE2)
  local inflight = 0
  for _, lane in pairs(lanes or {}) do
    if lane.state == C.LANE_WORKING then inflight = inflight + 1 end
  end
  local effective = math.max(0, n - inflight)
  if effective > max_circ then
    log_fn(string.format(
      "[ROBDispatcher] buffer has %d circuits (effective %d, max %d, inflight %d) — suppressing job creation",
      n, effective, max_circ, inflight))
    return false
  end
  return true
end

return AdmissionControl
