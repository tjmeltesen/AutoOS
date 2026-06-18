--[[
  AutoOS — Per-lane LCR dispatch FSM (v1: dual transposer, per_lane)

  Phases: idle -> settle -> transfer -> wait_complete -> extract -> wait_import -> idle
  LCR reference: references/LCR Universal Automation.lua
]]

local HW = require("hw")
local LaneSides = require("lane_sides")

local LaneDispatch = {}
LaneDispatch.__index = LaneDispatch

local STATE_IDLE = "idle"
local STATE_SETTLE = "settle"
local STATE_TRANSFER = "transfer"
local STATE_WAIT_COMPLETE = "wait_complete"
local STATE_EXTRACT = "extract"
local STATE_WAIT_IMPORT = "wait_import"

local FLUID_CHUNK = 1000000
local TRANSFER_RETRIES = 3
-- ponytail: ME dual interface may report getInventorySize=0; scan up to this many slots
local PULL_SCAN_MAX = 54

function LaneDispatch.new(deps)
  deps = deps or {}
  local self = setmetatable({}, LaneDispatch)
  self.config = deps.config or error("LaneDispatch.new: config required")
  self.component = deps.component or error("LaneDispatch.new: component required")
  self.circuit_manager = deps.circuit_manager or error("LaneDispatch.new: circuit_manager required")
  self.log = deps.log or function() end
  self.now = deps.now or function() return 0 end
  self.sleep = deps.sleep or HW.sleep
  self.monitor_poll_s = deps.monitor_poll_s or self.config.monitor_poll_s or 0.15
  self.staging_timeout_s = deps.staging_timeout_s or self.config.staging_timeout_s or 60
  self.settle_s = deps.settle_s or self.config.settle_s or 0.1
  self.completion_mode = deps.completion_mode or self.config.completion_mode or "both"
  self.circuit_bus_slot = self.config.circuit_bus_slot or 1
  self._lanes = {}
  self._rr_index = 1
  return self
end

local function lane_default(now, deadline_s)
  return {
    state = STATE_IDLE,
    deadline = now + deadline_s,
    settle_at = now,
    saw_active = false,
    staged_ok = false,
    fast_tick = false,
    last_error = nil,
    batch_outcome = nil, -- central: nil | "ok" | "failed"
    interface_wait_logged = false,
  }
end

function LaneDispatch:_lane(machine_id)
  local lane = self._lanes[machine_id]
  if lane then return lane end
  lane = lane_default(self.now(), self.staging_timeout_s)
  self._lanes[machine_id] = lane
  return lane
end

function LaneDispatch:get_lane_debug(machine_id)
  local lane = self:_lane(machine_id)
  return {
    state = lane.state,
    fast_tick = lane.fast_tick,
    saw_active = lane.saw_active,
    deadline = lane.deadline,
    last_error = lane.last_error,
    batch_outcome = lane.batch_outcome,
  }
end

function LaneDispatch:reset_lane(machine_id)
  self._lanes[machine_id] = lane_default(self.now(), self.staging_timeout_s)
end

function LaneDispatch:any_fast_tick()
  for _, lane in pairs(self._lanes) do
    if lane.fast_tick then return true end
  end
  return false
end

function LaneDispatch:is_lane_busy(machine_id)
  local lane = self._lanes[machine_id]
  return lane and lane.state ~= STATE_IDLE
end

function LaneDispatch:_item_pull_side(machine)
  if self:_is_central_mode() then
    return LaneSides.central_item_pull_side(machine)
  end
  return LaneSides.buffer_side(machine)
end

function LaneDispatch:_fluid_pull_side(machine)
  if self:_is_central_mode() then
    return LaneSides.central_fluid_pull_side(machine)
  end
  return LaneSides.fluid_buffer_side(machine)
end

function LaneDispatch:_require_interface_staging()
  if not self:_is_central_mode() then return false end
  local c = self.config.central
  if c and c.require_interface_staging == true then return true end
  return false
end

--- Central mode: items visible on dual interface face (side_buffer).
function LaneDispatch:verify_staged_on_interface(machine)
  local itp, err = self:_item_tp(machine)
  if not itp then return false, tostring(err) end
  local buf = self:_item_pull_side(machine)
  local start = self:_chest_start(machine)
  local size = self:_pull_scan_max(itp, buf)
  for slot = start, size do
    if self:_slot_size(itp, buf, slot) > 0 then
      return true, string.format("dual IF side %d slot %d has items", buf, slot)
    end
  end
  return false, string.format(
    "dual IF side %d empty — check side_buffer faces dual interface", buf)
end

--- Central mode: central_dispatch assigns lane; run settle → transfer from pull face.
---@return boolean ok
---@return string|nil err
function LaneDispatch:handoff_from_central(machine)
  local machine_id = machine.id
  if self:_require_interface_staging() then
    local ok, detail = self:verify_staged_on_interface(machine)
    if not ok then return false, detail end
  end
  local lane = self:_lane(machine_id)
  local now = self.now()
  lane.settle_at = now + self.settle_s
  lane.saw_active = false
  lane.staged_ok = false
  lane.last_error = nil
  lane.batch_outcome = nil
  lane.interface_wait_logged = false
  lane.deadline = now + self:_central_interface_wait_s()
  self:_transition(machine_id, lane, STATE_SETTLE, "central handoff")
  if self:_require_interface_staging() then
    local _, detail = self:verify_staged_on_interface(machine)
    self.log(string.format("[LaneDispatch] %s handoff ok (%s)", machine_id, detail or ""))
  else
    self.log(string.format("[LaneDispatch] %s handoff → dual IF side %d",
      machine_id, self:_item_pull_side(machine)))
  end
  return true
end

---@deprecated use handoff_from_central
function LaneDispatch:bind_from_central(machine)
  return self:handoff_from_central(machine)
end

function LaneDispatch:_is_central_mode()
  return self.config.input_mode == "central"
end

function LaneDispatch:_transition(machine_id, lane, next_state, reason)
  if lane.state ~= next_state then
    self.log(string.format("[LaneDispatch] %s %s -> %s (%s)", machine_id, lane.state, next_state, reason or ""))
    lane.state = next_state
  end
  lane.fast_tick = next_state ~= STATE_IDLE
end

function LaneDispatch:_chest_start(machine)
  return machine.chest_slot_start or self.config.chest_slot_start or 1
end

function LaneDispatch:_item_tp(machine)
  local addr = machine.item_transposer_address or machine.transposer_address
  return HW.require_proxy(self.component, "transposer", addr, "item transposer")
end

function LaneDispatch:_fluid_tp(machine)
  return HW.require_proxy(self.component, "transposer", machine.fluid_transposer_address, "fluid transposer")
end

function LaneDispatch:_slot_count(tp, side)
  if not tp or not tp.getInventorySize then return 0 end
  local ok, n = pcall(tp.getInventorySize, side)
  return ok and type(n) == "number" and n or 0
end

--- Max slot index to scan on a pull face (dual IF may lie about inventory size).
function LaneDispatch:_pull_scan_max(tp, side)
  local n = self:_slot_count(tp, side)
  if n > 0 then return n end
  return PULL_SCAN_MAX
end

function LaneDispatch:_slot_size(tp, side, slot)
  if not tp then return 0 end
  if tp.getStackInSlot then
    local ok, st = pcall(tp.getStackInSlot, side, slot)
    if ok and type(st) == "table" then return st.size or 0 end
  end
  if tp.getSlotStackSize then
    local ok, n = pcall(tp.getSlotStackSize, side, slot)
    return ok and type(n) == "number" and n or 0
  end
  return 0
end

function LaneDispatch:_central_interface_wait_s()
  local c = self.config.central
  if c and type(c.interface_wait_s) == "number" then return c.interface_wait_s end
  return self.staging_timeout_s
end

function LaneDispatch:_pull_face_ready(item_tp, fluid_tp, machine)
  if item_tp and self:_buffer_has_items(item_tp, machine) then return true end
  if fluid_tp and self:_buffer_has_fluid(fluid_tp, machine) then return true end
  return false
end

function LaneDispatch:_fluid_level(tp, side)
  if not tp or not tp.getTankLevel then return 0 end
  local ok, lvl = pcall(tp.getTankLevel, side, 1)
  return ok and type(lvl) == "number" and lvl or 0
end

function LaneDispatch:_buffer_has_items(item_tp, machine)
  local side = LaneSides.buffer_side(machine)
  local start = self:_chest_start(machine)
  local size = self:_pull_scan_max(item_tp, side)
  for slot = start, size do
    if self:_slot_size(item_tp, side, slot) > 0 then return true end
  end
  return false
end

function LaneDispatch:_buffer_has_fluid(fluid_tp, machine)
  local side = LaneSides.fluid_buffer_side(machine)
  if fluid_tp.getTankCount then
    local ok, n = pcall(fluid_tp.getTankCount, side)
    if ok and type(n) == "number" and n == 0 then return false end
  end
  return self:_fluid_level(fluid_tp, side) > 0
end

function LaneDispatch:_adapter_has_items(adapter, side)
  if type(side) ~= "number" then return nil, "buffer_adapter_side required" end
  if adapter.getInventorySize and adapter.getStackInSlot then
    local ok_size, size = pcall(adapter.getInventorySize, side)
    if ok_size and type(size) == "number" and size > 0 then
      for slot = 1, math.min(size, 12) do
        local ok_slot, st = pcall(adapter.getStackInSlot, side, slot)
        if ok_slot and type(st) == "table" and (st.size or 0) > 0 then return true end
      end
      return false
    end
  end
  return nil, "adapter has no supported inventory methods"
end

function LaneDispatch:_buffer_gate(machine)
  if not machine.buffer_adapter_address or machine.buffer_adapter_address == "" then
    return true
  end
  local adapter, _ = HW.proxy(self.component, machine.buffer_adapter_address, "adapter")
  if not adapter then return nil, "buffer adapter proxy failed" end
  return self:_adapter_has_items(adapter, machine.buffer_adapter_side)
end

function LaneDispatch:_buffer_ready(item_tp, fluid_tp, machine)
  local items = item_tp and self:_buffer_has_items(item_tp, machine)
  local fluids = fluid_tp and self:_buffer_has_fluid(fluid_tp, machine)
  return items or fluids
end

function LaneDispatch:_transfer_fluids(fluid_tp, machine)
  local from_side = self:_fluid_pull_side(machine)
  if self:_fluid_level(fluid_tp, from_side) <= 0 then return false end
  local to_side = LaneSides.fluid_hatch_side(machine)
  local moved_any = false
  for _ = 1, 32 do
    local ok, result = pcall(fluid_tp.transferFluid, from_side, to_side, FLUID_CHUNK)
    if not ok or result == false or result == 0 then break end
    moved_any = true
  end
  return moved_any
end

function LaneDispatch:_transfer_items(item_tp, machine)
  local from_side = self:_item_pull_side(machine)
  local to_side = LaneSides.bus_side(machine)
  local start = self:_chest_start(machine)
  local size = self:_pull_scan_max(item_tp, from_side)
  local moved_any = false
  for slot = start, size do
    local count = self:_slot_size(item_tp, from_side, slot)
    if count > 0 then
      for _ = 1, TRANSFER_RETRIES do
        local ok, moved = pcall(item_tp.transferItem, from_side, to_side, count, slot)
        if ok and moved and moved >= 1 then
          moved_any = true
          break
        end
        ok, moved = pcall(item_tp.transferItem, from_side, to_side, 1, slot)
        if ok and moved and moved >= 1 then
          moved_any = true
          break
        end
        self.sleep(0.05)
      end
    end
  end
  return moved_any
end

function LaneDispatch:_fluid_drained(fluid_tp, machine)
  local side = LaneSides.fluid_hatch_side(machine)
  return self:_fluid_level(fluid_tp, side) == 0
end

function LaneDispatch:_item_drained(item_tp, machine)
  local side = LaneSides.bus_side(machine)
  local after_slot = self.circuit_bus_slot + 1
  return self:_slot_size(item_tp, side, after_slot) == 0
end

function LaneDispatch:_drain_complete(item_tp, fluid_tp, machine)
  local fluid_ok = not fluid_tp or self:_fluid_drained(fluid_tp, machine)
  local item_ok = not item_tp or self:_item_drained(item_tp, machine)
  return fluid_ok and item_ok
end

function LaneDispatch:_completion_ready(lane, poll_status, item_tp, fluid_tp, machine)
  if poll_status and poll_status.active then
    lane.saw_active = true
  end

  local drained = self:_drain_complete(item_tp, fluid_tp, machine)
  if not drained then return false end

  -- ponytail: central push must reach lane bus; never "complete" on empty ghost batch
  if self:_is_central_mode() and not lane.saw_active then
    return false
  end

  local mode = self.completion_mode
  if mode == "drain" then return true end

  local adapter_done = lane.saw_active and poll_status and not poll_status.active
  if mode == "adapter" then
    return adapter_done or (self.now() >= lane.deadline)
  end

  -- both: adapter edge preferred; drain-only fallback after timeout or no adapter
  if adapter_done then return true end
  if poll_status and not poll_status.available then return true end
  if lane.saw_active and not poll_status.active then return true end
  if self.now() >= lane.deadline then return true end
  return false
end

function LaneDispatch:tick_lane(machine, poll_status)
  local machine_id = machine.id
  local lane = self:_lane(machine_id)
  local events = {}
  local now = self.now()

  local item_tp, item_err
  local fluid_tp, fluid_err

  local function ensure_item_tp()
    if item_tp then return item_tp end
    item_tp, item_err = self:_item_tp(machine)
    return item_tp
  end

  local function ensure_fluid_tp()
    if fluid_tp then return fluid_tp end
    fluid_tp, fluid_err = self:_fluid_tp(machine)
    return fluid_tp
  end

  if lane.state == STATE_IDLE then
    lane.fast_tick = false
    lane.saw_active = false

    if self:_is_central_mode() then
      return false, events
    end

    local gate, gate_err = self:_buffer_gate(machine)
    if gate == false then return false, events end
    if gate == nil and gate_err then
      lane.last_error = "buffer adapter: " .. gate_err
    end

    local itp = ensure_item_tp()
    local ftp = ensure_fluid_tp()
    if not itp then
      return false, { { type = "recover_failed", detail = tostring(item_err) } }
    end
    if not ftp then
      return false, { { type = "recover_failed", detail = tostring(fluid_err) } }
    end

    if not self:_buffer_ready(itp, ftp, machine) then
      return false, events
    end

    lane.settle_at = now + self.settle_s
    lane.deadline = now + self.staging_timeout_s
    self:_transition(machine_id, lane, STATE_SETTLE, "buffer ready")
    events[#events + 1] = { type = "buffer_ready", detail = "inputs detected" }
    return true, events
  end

  if lane.state == STATE_SETTLE then
    lane.fast_tick = true
    if now < lane.settle_at then return true, events end

    if self:_is_central_mode() then
      local itp = ensure_item_tp()
      local ftp = ensure_fluid_tp()
      if not itp or not ftp then
        return true, { { type = "recover_failed", detail = "transposer unavailable" } }
      end
      if not self:_pull_face_ready(itp, ftp, machine) then
        if now >= lane.deadline then
          local pull = self:_item_pull_side(machine)
          local detail = self.circuit_manager:describe_face(itp, pull)
          lane.last_error = string.format(
            "dual IF side %d empty after wait (%s)", pull, detail)
          lane.batch_outcome = "failed"
          self:_transition(machine_id, lane, STATE_IDLE, "dual IF wait timeout")
          events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
          return false, events
        end
        if not lane.interface_wait_logged then
          lane.interface_wait_logged = true
          self.log(string.format("[LaneDispatch] %s waiting for dual IF side %d",
            machine_id, self:_item_pull_side(machine)))
        end
        return true, events
      end
      lane.interface_wait_logged = nil
    end

    self:_transition(machine_id, lane, STATE_TRANSFER, "settle done")
    return true, events
  end

  if lane.state == STATE_TRANSFER then
    lane.fast_tick = true
    local itp = ensure_item_tp()
    local ftp = ensure_fluid_tp()
    if not itp or not ftp then
      return true, { { type = "recover_failed", detail = "transposer unavailable" } }
    end

    local moved_items = self:_transfer_items(itp, machine)
    local moved_fluids = self:_transfer_fluids(ftp, machine)
    if self:_is_central_mode() and not moved_items and not moved_fluids then
      local pull = self:_item_pull_side(machine)
      local detail = self.circuit_manager:describe_face(itp, pull)
      lane.last_error = string.format("no items moved from dual IF side %d (%s)", pull, detail)
      lane.batch_outcome = "failed"
      self:_transition(machine_id, lane, STATE_IDLE, "transfer empty")
      events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
      return false, events
    end
    lane.saw_active = false
    lane.deadline = now + self.staging_timeout_s
    self:_transition(machine_id, lane, STATE_WAIT_COMPLETE, "transfer done")
    events[#events + 1] = { type = "staged", detail = "buffer -> machine" }
    return true, events
  end

  if lane.state == STATE_WAIT_COMPLETE then
    lane.fast_tick = true
    local itp = ensure_item_tp()
    local ftp = ensure_fluid_tp()
    if not itp or not ftp then
      return true, { { type = "recover_failed", detail = "transposer unavailable" } }
    end

    if self:_completion_ready(lane, poll_status, itp, ftp, machine) then
      self:_transition(machine_id, lane, STATE_EXTRACT, "processing complete")
      events[#events + 1] = { type = "extract_start", detail = "drain/adapter complete" }
      return true, events
    end

    if now >= lane.deadline then
      if self:_is_central_mode() and not lane.saw_active then
        lane.last_error = lane.last_error or "machine never active after lane transfer"
        lane.batch_outcome = "failed"
        self:_transition(machine_id, lane, STATE_IDLE, "never ran — check interface→bus wiring")
        lane.staged_ok = false
        events[#events + 1] = {
          type = "recover_failed",
          detail = lane.last_error,
        }
        return false, events
      end
      self:_transition(machine_id, lane, STATE_EXTRACT, "wait timeout")
      events[#events + 1] = { type = "extract_start", detail = "timeout" }
    end
    return true, events
  end

  if lane.state == STATE_EXTRACT then
    lane.fast_tick = true
    local itp = ensure_item_tp()
    if not itp then
      return true, { { type = "recover_failed", detail = tostring(item_err) } }
    end

    local bus_side = LaneSides.bus_side(machine)
    local return_side = LaneSides.return_side(machine)
    local return_slot = LaneSides.return_slot(machine)
    local circuit_slot = self.circuit_bus_slot

    local size = self:_slot_size(itp, bus_side, circuit_slot)
    if size <= 0 then
      if self:_is_central_mode() then
        lane.last_error = "no circuit on bus after transfer"
        lane.batch_outcome = "failed"
      end
      self:_transition(machine_id, lane, STATE_IDLE, "no circuit on bus")
      lane.staged_ok = false
      events[#events + 1] = {
        type = self:_is_central_mode() and "recover_failed" or "recover_ok",
        detail = "no circuit on bus",
      }
      return false, events
    end

    local moved, err = self.circuit_manager:transfer_one(itp, bus_side, return_side, circuit_slot, return_slot)
    if moved >= 1 then
      lane.deadline = now + self.staging_timeout_s
      self:_transition(machine_id, lane, STATE_WAIT_IMPORT, "circuit extracted")
      return true, events
    end

    lane.last_error = "extract failed: " .. tostring(err)
    events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
    return true, events
  end

  -- STATE_WAIT_IMPORT
  lane.fast_tick = true
  local itp = ensure_item_tp()
  if not itp then
    return true, { { type = "recover_failed", detail = tostring(item_err) } }
  end

  local return_side = LaneSides.return_side(machine)
  local return_slot = LaneSides.return_slot(machine) or 1
  if self:_slot_size(itp, return_side, return_slot) == 0 then
    lane.saw_active = false
    lane.last_error = nil
    if self:_is_central_mode() then lane.batch_outcome = "ok" end
    self:_transition(machine_id, lane, STATE_IDLE, "circuit imported")
    events[#events + 1] = { type = "recover_ok", detail = "circuit returned" }
    return false, events
  end

  if now >= lane.deadline then
    if self:_is_central_mode() then
      lane.batch_outcome = "failed"
      lane.last_error = "import timeout on return face"
    end
    events[#events + 1] = { type = "recover_failed", detail = lane.last_error or "import timeout on return face" }
    self:_transition(machine_id, lane, STATE_IDLE, "import timeout")
    return false, events
  end

  return true, events
end

--- Round-robin: return machine ids in rotated order (for callers that batch lanes).
function LaneDispatch:lane_order(machines)
  local n = #machines
  if n == 0 then return {} end
  local out = {}
  local start = self._rr_index
  for i = 0, n - 1 do
    local idx = ((start - 1 + i) % n) + 1
    out[#out + 1] = machines[idx]
  end
  return out
end

function LaneDispatch:advance_round_robin(machines)
  if #machines > 0 then
    self._rr_index = (self._rr_index % #machines) + 1
  end
end

return LaneDispatch
