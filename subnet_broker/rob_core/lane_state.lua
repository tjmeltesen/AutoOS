--[[
  AutoOS — LaneState FSM
  Encapsulates all lane state transitions and validation.
  States: IDLE → WORKING → IDLE|FAULTED; FAULTED → IDLE (recovery).
]]
local C = require("rob_core.constants")

local LaneState = {}

--- Create a new lane for a machine_id.
--- @return table lane record
function LaneState.create(machine_id, now_fn)
  return {
    state = C.LANE_IDLE,
    current_job_id = nil,
    locked_resources = {},
    deadline = 0,
    state_entered_at = (now_fn and now_fn()) or 0,
    last_error = nil,
  }
end

--- Reset a lane to IDLE, releasing resources via the provided callback.
--- @param lane table  lane record (mutated in place)
--- @param reason string|nil  reason for reset
--- @param release_fn function  called as release_fn(lane) to free locks
--- @param now_fn function|nil
function LaneState.reset(lane, reason, release_fn, now_fn)
  if release_fn then release_fn(lane) end
  lane.state = C.LANE_IDLE
  lane.current_job_id = nil
  lane.locked_resources = {}
  lane.deadline = 0
  lane.state_entered_at = (now_fn and now_fn()) or 0
  lane.last_error = reason
end

--- Transition a lane to WORKING state.
function LaneState.assign(lane, job_id, resources, deadline, now_fn)
  lane.state = C.LANE_WORKING
  lane.current_job_id = job_id
  lane.locked_resources = resources or {}
  lane.deadline = deadline or 0
  lane.state_entered_at = (now_fn and now_fn()) or 0
  lane.last_error = nil
end

--- Transition a WORKING lane to IDLE (job done).
function LaneState.complete(lane)
  lane.state = C.LANE_IDLE
  lane.current_job_id = nil
  lane.last_error = nil
end

--- Transition a WORKING lane to FAULTED (job failed or watchdog).
function LaneState.fault(lane, reason)
  lane.state = C.LANE_FAULTED
  lane.current_job_id = nil
  lane.last_error = reason
end

--- Recover a FAULTED lane to IDLE.
function LaneState.recover(lane)
  if lane.state == C.LANE_FAULTED then
    lane.state = C.LANE_IDLE
    lane.current_job_id = nil
    return true
  end
  return false
end

-- State queries (direct field access preserved for hot-path performance)
function LaneState.is_idle(lane)      return lane and lane.state == C.LANE_IDLE end
function LaneState.is_working(lane)   return lane and lane.state == C.LANE_WORKING end
function LaneState.is_faulted(lane)   return lane and lane.state == C.LANE_FAULTED end

return LaneState
