--[[
  AutoOS — Per-lane circuit lifecycle FSM (Array Watch)

  State flow:
    idle -> staging -> monitoring -> extraction -> idle

  Activity signal source: poll_status.active (gt_machine.isMachineActive()).
]]

local HW = require("hw")
local LaneSides = require("lane_sides")

local CircuitLoop = {}
CircuitLoop.__index = CircuitLoop

local STATE_IDLE = "idle"
local STATE_STAGING = "staging"
local STATE_MONITORING = "monitoring"
local STATE_EXTRACTION = "extraction"

function CircuitLoop.new(deps)
  deps = deps or {}
  local self = setmetatable({}, CircuitLoop)
  self.config = deps.config or error("CircuitLoop.new: config required")
  self.component = deps.component or error("CircuitLoop.new: component required")
  self.circuit_manager = deps.circuit_manager or error("CircuitLoop.new: circuit_manager required")
  self.log = deps.log or function() end
  self.now = deps.now or function() return 0 end
  self.monitor_poll_s = deps.monitor_poll_s or self.config.monitor_poll_s or 0.15
  self.staging_timeout_s = deps.staging_timeout_s or self.config.staging_timeout_s or 3
  self._lanes = {}
  return self
end

local function lane_default(now)
  return {
    state = STATE_IDLE,
    staging_deadline = now,
    saw_active = false,
    fast_tick = false,
    last_error = nil,
  }
end

function CircuitLoop:_lane(machine_id)
  local lane = self._lanes[machine_id]
  if lane then return lane end
  lane = lane_default(self.now())
  self._lanes[machine_id] = lane
  return lane
end

function CircuitLoop:get_lane_debug(machine_id)
  local lane = self:_lane(machine_id)
  return {
    state = lane.state,
    fast_tick = lane.fast_tick,
    saw_active = lane.saw_active,
    staging_deadline = lane.staging_deadline,
    last_error = lane.last_error,
  }
end

function CircuitLoop:reset_lane(machine_id)
  self._lanes[machine_id] = lane_default(self.now())
end

function CircuitLoop:any_fast_tick()
  for _, lane in pairs(self._lanes) do
    if lane.fast_tick then return true end
  end
  return false
end

function CircuitLoop:_transition(machine_id, lane, next_state, reason)
  if lane.state ~= next_state then
    self.log(string.format("[CircuitLoop] %s %s -> %s (%s)", machine_id, lane.state, next_state, reason or ""))
    lane.state = next_state
  end
  lane.fast_tick = next_state ~= STATE_IDLE
end

local function is_active(st)
  return st and st.available and st.active or false
end

local function has_stack(st)
  return type(st) == "table" and (st.size or 0) > 0
end

function CircuitLoop:_adapter_has_items(adapter, side)
  if type(side) ~= "number" then
    return nil, "buffer_adapter_side is required with buffer_adapter_address"
  end

  if adapter.getInventorySize and adapter.getStackInSlot then
    local ok_size, size = pcall(adapter.getInventorySize, side)
    if ok_size and type(size) == "number" and size > 0 then
      for slot = 1, math.min(size, 12) do
        local ok_slot, st = pcall(adapter.getStackInSlot, side, slot)
        if ok_slot and has_stack(st) then return true end
      end
      return false
    end
  end

  if adapter.getAllStacks then
    local ok_all, stacks = pcall(adapter.getAllStacks, side)
    if ok_all and stacks then
      local rows = stacks
      if type(stacks) == "table" and type(stacks.getAll) == "function" then
        local ok_rows, resolved = pcall(stacks.getAll, stacks)
        if ok_rows then rows = resolved end
      end
      if type(rows) == "table" then
        for _, st in pairs(rows) do
          if has_stack(st) then return true end
        end
        return false
      end
    end
  end

  return nil, "adapter has no supported inventory methods"
end

function CircuitLoop:_buffer_gate(machine)
  if not machine.buffer_adapter_address or machine.buffer_adapter_address == "" then
    return true
  end
  local adapter, aerr = HW.proxy(self.component, machine.buffer_adapter_address, "adapter")
  if not adapter then
    return nil, "buffer adapter proxy failed: " .. tostring(aerr)
  end
  return self:_adapter_has_items(adapter, machine.buffer_adapter_side)
end

function CircuitLoop:_safe_find(tp, side, circuit_damage)
  local ok, slot, stack = pcall(self.circuit_manager.find_circuit_slot, self.circuit_manager, tp, side, circuit_damage)
  if not ok then return nil, nil, tostring(slot) end
  return slot, stack, nil
end

function CircuitLoop:_safe_transfer(tp, from_side, to_side, from_slot, to_slot)
  local ok, moved, err = pcall(
    self.circuit_manager.transfer_one,
    self.circuit_manager, tp, from_side, to_side, from_slot, to_slot
  )
  if not ok then return 0, tostring(moved) end
  return moved, err
end

function CircuitLoop:tick_lane(machine, poll_status)
  local machine_id = machine.id
  local lane = self:_lane(machine_id)
  local events = {}
  local tp
  local function ensure_tp()
    if tp then return tp end
    local proxy, tp_err = HW.require_proxy(self.component, "transposer", machine.transposer_address, "transposer")
    if not proxy then
      lane.last_error = tp_err
      lane.fast_tick = false
      return nil, tp_err
    end
    tp = proxy
    return tp
  end

  local side_buffer = LaneSides.buffer_side(machine)
  local side_bus = LaneSides.bus_side(machine)
  local side_return = LaneSides.return_side(machine)
  local to_slot = LaneSides.return_slot(machine)
  local input_slot = machine.input_slot or 1
  local now = self.now()

  if lane.state == STATE_IDLE then
    lane.fast_tick = false
    lane.saw_active = false
    lane.staging_deadline = now + self.staging_timeout_s

    local has_items, gate_err = self:_buffer_gate(machine)
    if has_items == false then
      return false, events
    end
    if has_items == nil and gate_err then
      lane.last_error = "buffer adapter check failed, falling back: " .. gate_err
    end

    local tp_proxy, tp_err = ensure_tp()
    if not tp_proxy then
      return false, {
        { type = "recover_failed", detail = "transposer unavailable: " .. tostring(tp_err) },
      }
    end
    local slot, _, err = self:_safe_find(tp, side_buffer, nil)
    if err then
      lane.last_error = "buffer scan failed: " .. err
      return false, events
    end
    if slot then
      lane.staging_deadline = now + self.staging_timeout_s
      self:_transition(machine_id, lane, STATE_STAGING, "circuit found on buffer")
      events[#events + 1] = { type = "staging_start", detail = "slot " .. tostring(slot) }
      return true, events
    end
    return false, events
  end

  if lane.state == STATE_STAGING then
    lane.fast_tick = true
    local tp_proxy, tp_err = ensure_tp()
    if not tp_proxy then
      return true, { { type = "recover_failed", detail = "transposer unavailable: " .. tostring(tp_err) } }
    end

    local bus_slot, _, bus_err = self:_safe_find(tp, side_bus, nil)
    if bus_err then
      lane.last_error = "bus scan failed: " .. bus_err
      return true, events
    end
    if bus_slot then
      self:_transition(machine_id, lane, STATE_MONITORING, "bus already stocked")
      return true, events
    end

    local buffer_slot, _, scan_err = self:_safe_find(tp, side_buffer, nil)
    if scan_err then
      lane.last_error = "buffer scan failed: " .. scan_err
      return true, events
    end

    if not buffer_slot then
      if now >= lane.staging_deadline then
        self:_transition(machine_id, lane, STATE_IDLE, "staging timeout with empty buffer")
      end
      return true, events
    end

    local moved, move_err = self:_safe_transfer(tp, side_buffer, side_bus, buffer_slot, input_slot)
    if moved >= 1 then
      lane.saw_active = false
      self:_transition(machine_id, lane, STATE_MONITORING, "buffer -> bus moved")
      events[#events + 1] = { type = "staged", detail = "moved 1 circuit to bus" }
      return true, events
    end

    if now >= lane.staging_deadline then
      self:_transition(machine_id, lane, STATE_EXTRACTION, "staging timeout")
    else
      lane.last_error = "stage transfer failed: " .. tostring(move_err or "no move")
    end
    return true, events
  end

  if lane.state == STATE_MONITORING then
    lane.fast_tick = true
    local active = is_active(poll_status)
    if active then
      lane.saw_active = true
      return true, events
    end

    if lane.saw_active or now >= lane.staging_deadline then
      local reason = lane.saw_active and "processing complete" or "start timeout"
      self:_transition(machine_id, lane, STATE_EXTRACTION, reason)
      events[#events + 1] = { type = "extract_start", detail = reason }
    end
    return true, events
  end

  -- STATE_EXTRACTION
  lane.fast_tick = true
  local tp_proxy, tp_err = ensure_tp()
  if not tp_proxy then
    return true, { { type = "recover_failed", detail = "transposer unavailable: " .. tostring(tp_err) } }
  end
  local bus_slot, _, bus_err = self:_safe_find(tp, side_bus, nil)
  if bus_err then
    lane.last_error = "extract scan failed: " .. bus_err
    return true, events
  end
  if not bus_slot then
    self:_transition(machine_id, lane, STATE_IDLE, "nothing on bus")
    events[#events + 1] = { type = "recover_ok", detail = "no circuit on bus" }
    return false, events
  end

  local moved, move_err = self:_safe_transfer(tp, side_bus, side_return, bus_slot, to_slot)
  if moved >= 1 then
    lane.last_error = nil
    lane.saw_active = false
    self:_transition(machine_id, lane, STATE_IDLE, "circuit returned")
    events[#events + 1] = { type = "recover_ok", detail = "bus -> return moved" }
    return false, events
  end

  lane.last_error = "extract transfer failed: " .. tostring(move_err or "no move")
  events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
  return true, events
end

return CircuitLoop
