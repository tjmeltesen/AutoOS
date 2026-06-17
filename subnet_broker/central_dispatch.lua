--[[
  AutoOS — Central buffer dispatch (multipurpose RR port)

  AE2 → shared chest/tank → central transposers → next available machine (RR).
  Lane tail (wait_complete → extract → return) stays in lane_dispatch.lua.
]]

local HW = require("hw")
local LaneSides = require("lane_sides")
local MachinePoll = require("machine_poll")

local CentralDispatch = {}
CentralDispatch.__index = CentralDispatch

local STATE_IDLE = "central_idle"
local STATE_SETTLE = "central_settle"
local STATE_BOUND = "central_bound"

local FLUID_CHUNK = 1000000
local TRANSFER_RETRIES = 3

function CentralDispatch.new(deps)
  deps = deps or {}
  local self = setmetatable({}, CentralDispatch)
  self.config = deps.config or error("CentralDispatch.new: config required")
  self.component = deps.component or error("CentralDispatch.new: component required")
  self.circuit_manager = deps.circuit_manager or error("CentralDispatch.new: circuit_manager required")
  self.lane_dispatch = deps.lane_dispatch
  self.log = deps.log or function() end
  self.now = deps.now or function() return 0 end
  self.sleep = deps.sleep or HW.sleep
  self.settle_s = deps.settle_s or self.config.settle_s or 0.1
  self._rr_index = 1
  self._state = STATE_IDLE
  self._settle_at = 0
  self._bound_machine_id = nil
  self._last_wait_log = 0
  self._fast_tick = false
  return self
end

function CentralDispatch:get_debug()
  return {
    state = self._state,
    bound_machine = self._bound_machine_id,
    rr_index = self._rr_index,
    fast_tick = self._fast_tick,
  }
end

function CentralDispatch:any_fast_tick()
  return self._fast_tick
    or (self._state ~= STATE_IDLE)
    or false
end

function CentralDispatch:_central_cfg()
  return self.config.central or {}
end

function CentralDispatch:_chest_start()
  local c = self:_central_cfg()
  return c.chest_slot_start or self.config.chest_slot_start or 1
end

function CentralDispatch:_item_tp()
  local c = self:_central_cfg()
  return HW.require_proxy(self.component, "transposer", c.item_transposer_address, "central item TP")
end

function CentralDispatch:_fluid_tp()
  local c = self:_central_cfg()
  return HW.require_proxy(self.component, "transposer", c.fluid_transposer_address, "central fluid TP")
end

function CentralDispatch:_lane_item_tp(machine)
  local addr = LaneSides.item_transposer_address(machine)
  return HW.require_proxy(self.component, "transposer", addr, "lane item TP")
end

function CentralDispatch:_lane_fluid_tp(machine)
  return HW.require_proxy(self.component, "transposer", machine.fluid_transposer_address, "lane fluid TP")
end

function CentralDispatch:_slot_count(tp, side)
  if not tp or not tp.getInventorySize then return 0 end
  local ok, n = pcall(tp.getInventorySize, side)
  return ok and type(n) == "number" and n or 0
end

function CentralDispatch:_slot_size(tp, side, slot)
  if not tp or not tp.getSlotStackSize then return 0 end
  local ok, n = pcall(tp.getSlotStackSize, side, slot)
  return ok and type(n) == "number" and n or 0
end

function CentralDispatch:_fluid_level(tp, side)
  if not tp or not tp.getTankLevel then return 0 end
  local ok, lvl = pcall(tp.getTankLevel, side, 1)
  return ok and type(lvl) == "number" and lvl or 0
end

function CentralDispatch:_buffer_side()
  return LaneSides.central_buffer_side(self.config)
end

function CentralDispatch:_count_circuits(item_tp, side, start_slot)
  local n = 0
  local size = self:_slot_count(item_tp, side)
  for slot = start_slot or 1, size do
    local st = item_tp.getStackInSlot and item_tp.getStackInSlot(side, slot)
    if self.circuit_manager:stack_is_circuit(st) then n = n + 1 end
  end
  return n
end

function CentralDispatch:_central_has_items(item_tp)
  local side = self:_buffer_side()
  local start = self:_chest_start()
  local size = self:_slot_count(item_tp, side)
  for slot = start, size do
    if self:_slot_size(item_tp, side, slot) > 0 then return true end
  end
  return false
end

function CentralDispatch:_central_has_fluid(fluid_tp)
  local side = self:_buffer_side()
  if fluid_tp.getTankCount then
    local ok, n = pcall(fluid_tp.getTankCount, side)
    if ok and type(n) == "number" and n == 0 then return false end
  end
  return self:_fluid_level(fluid_tp, side) > 0
end

function CentralDispatch:_central_buffer_ready(item_tp, fluid_tp)
  return (item_tp and self:_central_has_items(item_tp))
    or (fluid_tp and self:_central_has_fluid(fluid_tp))
end

function CentralDispatch:_central_buffer_empty(item_tp, fluid_tp)
  local items_empty = not item_tp or not self:_central_has_items(item_tp)
  local fluid_empty = not fluid_tp or not self:_central_has_fluid(fluid_tp)
  return items_empty and fluid_empty
end

function CentralDispatch:_central_admission_ok(item_tp)
  local c = self:_central_cfg()
  local max_circ = c.max_circuits_in_buffer or self.config.max_circuits_in_buffer
  if not max_circ or max_circ < 1 or not item_tp then return true end
  local side = self:_buffer_side()
  local n = self:_count_circuits(item_tp, side, self:_chest_start())
  if n > max_circ then
    self.log(string.format("[CentralDispatch] buffer has %d circuits (max %d)", n, max_circ))
    return false
  end
  return true
end

function CentralDispatch:_bus_empty(item_tp, machine)
  local side = LaneSides.bus_side(machine)
  local size = self:_slot_count(item_tp, side)
  for slot = 1, size do
    if self:_slot_size(item_tp, side, slot) > 0 then return false end
  end
  return true
end

function CentralDispatch:_return_empty(item_tp, machine)
  if self.config.require_empty_return == false then return true end
  local side = LaneSides.return_side(machine)
  local slot = LaneSides.return_slot(machine) or 1
  if self:_slot_size(item_tp, side, slot) > 0 then return false end
  local size = self:_slot_count(item_tp, side)
  for s = 1, size do
    if self:_slot_size(item_tp, side, s) > 0 then return false end
  end
  return true
end

function CentralDispatch:_machine_available(machine, poll_status, lane_dispatch)
  if not poll_status or not poll_status.available or not poll_status.healthy then
    return false
  end
  if not MachinePoll.is_idle(poll_status) then return false end
  if lane_dispatch and lane_dispatch:is_lane_busy(machine.id) then return false end

  local item_tp = self:_lane_item_tp(machine)
  local fluid_tp = self:_lane_fluid_tp(machine)
  if not item_tp or not fluid_tp then return false end
  if not self:_bus_empty(item_tp, machine) then return false end
  if self:_fluid_level(fluid_tp, LaneSides.fluid_hatch_side(machine)) > 0 then return false end
  if not self:_return_empty(item_tp, machine) then return false end
  return true
end

--- Port of multipurpose findAvailableOutputRR().
function CentralDispatch:find_available_machine_rr(machines, poll_results, lane_dispatch)
  machines = machines or self.config.machines
  local n = #machines
  if n == 0 then return nil end

  local start
  if self.config.do_round_robin ~= false then
    start = self._rr_index
  else
    start = 1
  end

  local function try_from(from_idx)
    for i = 0, n - 1 do
      local idx = ((from_idx - 1 + i) % n) + 1
      local m = machines[idx]
      local st = poll_results[m.id]
      if self:_machine_available(m, st, lane_dispatch) then
        if self.config.do_round_robin ~= false then
          self._rr_index = idx
        end
        return m, idx
      end
    end
    return nil
  end

  return try_from(start)
end

function CentralDispatch:_transfer_items_to_machine(central_item_tp, machine)
  local from_side = self:_buffer_side()
  local to_side = LaneSides.central_item_out_side(machine)
  if type(to_side) ~= "number" then return false end
  local start = self:_chest_start()
  local size = self:_slot_count(central_item_tp, from_side)
  local moved_any = false
  for slot = start, size do
    local count = self:_slot_size(central_item_tp, from_side, slot)
    if count > 0 then
      for _ = 1, TRANSFER_RETRIES do
        local ok, moved = pcall(central_item_tp.transferItem, from_side, to_side, count, slot)
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

function CentralDispatch:_transfer_fluids_to_machine(central_fluid_tp, machine)
  local from_side = self:_buffer_side()
  local to_side = LaneSides.central_fluid_out_side(machine)
  if type(to_side) ~= "number" then return false end
  local moved_any = false
  for _ = 1, 32 do
    local ok, result = pcall(central_fluid_tp.transferFluid, from_side, to_side, FLUID_CHUNK)
    if not ok or result == false or result == 0 then break end
    moved_any = true
  end
  return moved_any
end

function CentralDispatch:_transfer_central_to_machine(machine)
  local item_tp = self:_item_tp()
  local fluid_tp = self:_fluid_tp()
  if not item_tp or not fluid_tp then
    return false, "central transposer unavailable"
  end
  self:_transfer_fluids_to_machine(fluid_tp, machine)
  self:_transfer_items_to_machine(item_tp, machine)
  if not self:_central_buffer_empty(item_tp, fluid_tp) then
    self.log("[CentralDispatch] warning: central buffer not fully drained after transfer")
  end
  return true
end

function CentralDispatch:_advance_rr_after_push(idx, n)
  if self.config.do_round_robin ~= false and n > 0 then
    self._rr_index = (idx % n) + 1
  end
end

function CentralDispatch:tick(poll_results, lane_dispatch)
  lane_dispatch = lane_dispatch or self.lane_dispatch
  self._fast_tick = self._state ~= STATE_IDLE

  local item_tp = self:_item_tp()
  local fluid_tp = self:_fluid_tp()

  if self._state == STATE_BOUND then
    if not self._bound_machine_id then
      self._state = STATE_IDLE
      return {}
    end
    local dbg = lane_dispatch and lane_dispatch:get_lane_debug(self._bound_machine_id)
    if dbg and dbg.state == "idle" then
      self.log(string.format("[CentralDispatch] batch complete on %s", self._bound_machine_id))
      self._bound_machine_id = nil
      self._state = STATE_IDLE
    end
    return {}
  end

  if self._state == STATE_IDLE then
    if not self:_central_buffer_ready(item_tp, fluid_tp) then
      return {}
    end
    if not self:_central_admission_ok(item_tp) then
      return {}
    end
    self._settle_at = self.now() + self.settle_s
    self._state = STATE_SETTLE
    self.log("[CentralDispatch] central buffer ready → settle")
    self._fast_tick = true
    return { { type = "central_buffer_ready", detail = "inputs in central buffer" } }
  end

  if self._state == STATE_SETTLE then
    if self.now() < self._settle_at then return {} end
    if not self:_central_buffer_ready(item_tp, fluid_tp) then
      self._state = STATE_IDLE
      return {}
    end

    local machine, idx = self:find_available_machine_rr(
      self.config.machines, poll_results, lane_dispatch)
    if not machine then
      local now = self.now()
      if now - self._last_wait_log >= 5 then
        self._last_wait_log = now
        self.log("[CentralDispatch] CENTRAL_WAIT_OUTPUT — no available machine")
      end
      return { { type = "central_wait_output", detail = "all lanes busy or not empty" } }
    end

    local ok, err = self:_transfer_central_to_machine(machine)
    if not ok then
      self.log("[CentralDispatch] transfer failed: " .. tostring(err))
      return { { type = "central_transfer_failed", detail = tostring(err) } }
    end

    if lane_dispatch and lane_dispatch.bind_from_central then
      lane_dispatch:bind_from_central(machine.id)
    end

    self._bound_machine_id = machine.id
    self._state = STATE_BOUND
    self:_advance_rr_after_push(idx, #self.config.machines)
    self.log(string.format("[CentralDispatch] pushed batch → %s (RR idx %d)", machine.id, idx))
    return {
      { type = "central_staged", machine_id = machine.id, detail = "central → " .. machine.id },
    }
  end

  return {}
end

return CentralDispatch
