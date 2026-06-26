--[[
  AutoOS — Machine Selector
  Round-robin machine selection with health filtering and auto-recovery.
]]
local LaneState = require("rob_core.lane_state")
local C = require("rob_core.constants")

local MachineSelector = {}
MachineSelector.__index = MachineSelector

--- Create a new MachineSelector instance.
function MachineSelector.new(max_parallel_lanes)
  return setmetatable({
    _rr_index = 1,
    _max_parallel_lanes = max_parallel_lanes,
  }, MachineSelector)
end

--- Compute available lane budget.
function MachineSelector.available_budget(self, lanes)
  local max_lanes = self._max_parallel_lanes
  if not max_lanes or max_lanes < 1 then
    -- Default to total machine count if not configured
    return 999
  end
  local working = 0
  for _, lane in pairs(lanes or {}) do
    if LaneState.is_working(lane) then working = working + 1 end
  end
  return math.max(0, max_lanes - working)
end

--- Check if a machine is available for dispatch.
--- @param machine table  machine config
--- @param poll_status table  poll result
--- @param lanes table  machine_id -> lane
--- @param recover_fn function  called to auto-recover FAULTED lanes
function MachineSelector.is_available(machine, poll_status, lanes, recover_fn)
  if not machine or not machine.id then return false end
  if not poll_status then return false end
  if not poll_status.available then return false end
  if not poll_status.healthy then return false end

  local lane = lanes[machine.id]
  if lane then
    if LaneState.is_working(lane) then return false end
    if LaneState.is_faulted(lane) then
      -- Auto-recover: poll confirms healthy, lane state was stale
      if recover_fn then
        recover_fn(machine.id)
        return true
      end
      return false
    end
    return true  -- IDLE
  end

  -- No lane record → never dispatched → available
  return true
end

--- Round-robin through machines to find an available one.
--- @return table|nil machine
--- @return number|nil index (1-based)
--- @return string|nil diagnostics (if no machine found)
function MachineSelector.find_available(self, machines, poll_results, lanes, do_round_robin, recover_fn, log_fn)
  local n = #machines
  if n == 0 then return nil, nil end

  local start = do_round_robin ~= false and self._rr_index or 1

  for i = 0, n - 1 do
    local idx = ((start - 1 + i) % n) + 1
    local m = machines[idx]
    local st = poll_results and poll_results[m.id]
    if MachineSelector.is_available(m, st, lanes, recover_fn) then
      return m, idx
    end
  end

  -- Diagnostic: log why every machine was rejected
  if log_fn then
    local reasons = {}
    for _, m in ipairs(machines) do
      local st = poll_results and poll_results[m.id]
      local lane = lanes[m.id]
      local why = "?"
      if not st then
        why = "no_poll"
      elseif not st.available then
        why = "!available"
      elseif not st.healthy then
        why = "!healthy"
      elseif lane and LaneState.is_working(lane) then
        why = "lane=WORKING"
      elseif not lane and (st.active or st.has_work) then
        why = st.active and "active" or "has_work"
      elseif lane and LaneState.is_faulted(lane) then
        why = "lane=FAULTED"
      else
        why = "ok?"
      end
      reasons[#reasons + 1] = string.format("%s:%s", m.id, why)
    end
    log_fn(string.format("[ROBDispatcher] no available machine — rejected: %s",
      table.concat(reasons, " ")))
  end

  return nil, nil
end

--- Advance the round-robin cursor after a successful assignment.
function MachineSelector.advance(self, idx, machines, do_round_robin)
  local n = #machines
  if do_round_robin ~= false and n > 0 then
    self._rr_index = (idx % n) + 1
  end
end

return MachineSelector
