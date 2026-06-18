--[[
  AutoOS — Central buffer dispatch (storage bus + adapter monitor)

  AE2 → shared chest via storage bus → item adapter fingerprint + stabilize_s.
  RR picks idle lane → lane_dispatch handoff (no central transposers).
]]

local HW = require("hw")
local LaneSides = require("lane_sides")
local MachinePoll = require("machine_poll")

local CentralDispatch = {}
CentralDispatch.__index = CentralDispatch

local STATE_IDLE = "central_idle"
local STATE_STABILIZING = "central_stabilizing"
local STATE_ASSIGN = "central_assign"
local STATE_BOUND = "central_bound"
local FLUID_DROP_ITEM = "ae2fc:fluid_drop"

function CentralDispatch.new(deps)
  deps = deps or {}
  local self = setmetatable({}, CentralDispatch)
  self.config = deps.config or error("CentralDispatch.new: config required")
  self.component = deps.component or error("CentralDispatch.new: component required")
  self.circuit_manager = deps.circuit_manager or error("CentralDispatch.new: circuit_manager required")
  self.lane_dispatch = deps.lane_dispatch
  self.log = deps.log or function() end
  self.now = deps.now or function() return 0 end
  self._rr_index = 1
  self._state = STATE_IDLE
  self._bound_machine_id = nil
  self._last_wait_log = 0
  self._fast_tick = false
  self._fingerprint = nil
  self._stable_since = 0
  self._stabilize_logged = false
  self._last_handoff_log = 0
  self._last_fail_log = 0
  return self
end

function CentralDispatch:get_debug()
  return {
    state = self._state,
    bound_machine = self._bound_machine_id,
    rr_index = self._rr_index,
    fast_tick = self._fast_tick,
    stable_for = self._fingerprint and (self.now() - self._stable_since) or 0,
  }
end

function CentralDispatch:any_fast_tick()
  return self._fast_tick or self._state ~= STATE_IDLE
end

function CentralDispatch:_central_cfg()
  return self.config.central or {}
end

function CentralDispatch:_stabilize_s()
  local c = self:_central_cfg()
  if type(c.stabilize_s) == "number" then return c.stabilize_s end
  return 3.0
end

function CentralDispatch:_chest_start()
  local c = self:_central_cfg()
  return c.chest_slot_start or self.config.chest_slot_start or 1
end

function CentralDispatch:_item_adapter()
  local c = self:_central_cfg()
  if (c.monitor or "adapter") == "inventory_controller" then
    if not self.component.isAvailable or not self.component.isAvailable("inventory_controller") then
      return nil, "inventory_controller upgrade not installed"
    end
    return self.component.inventory_controller
  end
  if not c.buffer_adapter_address or c.buffer_adapter_address == "" then
    return nil, "central buffer_adapter_address not set"
  end
  local adapter, err = HW.proxy(self.component, c.buffer_adapter_address, "adapter")
  if not adapter then return nil, err or "item buffer adapter proxy failed" end
  return adapter
end

function CentralDispatch:_adapter_side()
  local c = self:_central_cfg()
  if (c.monitor or "adapter") == "inventory_controller" then
    return c.inventory_controller_side
  end
  return c.buffer_adapter_side
end

function CentralDispatch:_slot_count_on_adapter(adapter, side)
  if not adapter or not adapter.getInventorySize then return 0 end
  local ok, n = pcall(adapter.getInventorySize, side)
  return ok and type(n) == "number" and n or 0
end

function CentralDispatch:_slot_size_on_adapter(adapter, side, slot)
  if not adapter or not adapter.getStackInSlot then return 0 end
  local ok, st = pcall(adapter.getStackInSlot, side, slot)
  if ok and type(st) == "table" then return st.size or 0 end
  if adapter.getSlotStackSize then
    local ok2, n = pcall(adapter.getSlotStackSize, side, slot)
    return ok2 and type(n) == "number" and n or 0
  end
  return 0
end

function CentralDispatch:_stack_on_adapter(adapter, side, slot)
  if not adapter or not adapter.getStackInSlot then return nil end
  local ok, st = pcall(adapter.getStackInSlot, side, slot)
  if not ok or type(st) ~= "table" then return nil end
  if (st.size or 0) < 1 then return nil end
  return st
end

--- Build { slot = size, ... } for non-empty chest slots.
function CentralDispatch:_item_fingerprint(adapter, side)
  local fp = {}
  local start = self:_chest_start()
  local size = self:_slot_count_on_adapter(adapter, side)
  for slot = start, size do
    local n = self:_slot_size_on_adapter(adapter, side, slot)
    if n > 0 then fp[slot] = n end
  end
  return fp
end

function CentralDispatch:_batch_manifest(adapter, side)
  local out = { items = {}, fluids = {} }
  local start = self:_chest_start()
  local size = self:_slot_count_on_adapter(adapter, side)
  for slot = start, size do
    local st = self:_stack_on_adapter(adapter, side, slot)
    if st then
      if st.name == FLUID_DROP_ITEM then
        out.fluids[#out.fluids + 1] = {
          fluid_label = st.label and st.label:gsub("^drop of ", "") or nil,
          fluid_filter = { name = st.name, damage = st.damage or 0, label = st.label },
        }
      else
        out.items[#out.items + 1] = {
          slot = slot,
          name = st.name,
          damage = st.damage or 0,
          label = st.label,
          count = st.size or 1,
        }
      end
    end
  end
  return out
end

local function fingerprint_equal(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  for slot, n in pairs(a) do
    if b[slot] ~= n then return false end
  end
  for slot, n in pairs(b) do
    if a[slot] ~= n then return false end
  end
  return true
end

function CentralDispatch:_fingerprint_nonempty(fp)
  return fp and next(fp) ~= nil
end

function CentralDispatch:_count_circuits(adapter, side)
  if not adapter or not adapter.getStackInSlot then return 0 end
  local n = 0
  local start = self:_chest_start()
  local size = self:_slot_count_on_adapter(adapter, side)
  for slot = start, size do
    local ok, st = pcall(adapter.getStackInSlot, side, slot)
    if ok and self.circuit_manager:stack_is_circuit(st) then n = n + 1 end
  end
  return n
end

function CentralDispatch:_central_admission_ok(adapter, side)
  local c = self:_central_cfg()
  local max_circ = c.max_circuits_in_buffer or self.config.max_circuits_in_buffer
  if not max_circ or max_circ < 1 or not adapter then return true end
  local n = self:_count_circuits(adapter, side)
  if n > max_circ then
    self.log(string.format("[CentralDispatch] buffer has %d circuits (max %d)", n, max_circ))
    return false
  end
  return true
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

function CentralDispatch:find_available_machine_rr(machines, poll_results, lane_dispatch)
  machines = machines or self.config.machines
  local n = #machines
  if n == 0 then return nil end

  local start = self.config.do_round_robin ~= false and self._rr_index or 1

  for i = 0, n - 1 do
    local idx = ((start - 1 + i) % n) + 1
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

function CentralDispatch:_reset_stabilizing()
  self._fingerprint = nil
  self._stable_since = 0
  self._stabilize_logged = false
end

function CentralDispatch:_advance_rr_after_assign(idx, n)
  if self.config.do_round_robin ~= false and n > 0 then
    self._rr_index = (idx % n) + 1
  end
end

function CentralDispatch:find_handoff_target_rr(machines, poll_results, lane_dispatch)
  machines = machines or self.config.machines
  local n = #machines
  if n == 0 then return nil, nil, "no machines configured" end

  local start = self.config.do_round_robin ~= false and self._rr_index or 1

  for i = 0, n - 1 do
    local idx = ((start - 1 + i) % n) + 1
    local m = machines[idx]
    local st = poll_results[m.id]
    if self:_machine_available(m, st, lane_dispatch) then
      return m, idx, nil
    end
  end

  return nil, nil, nil
end

function CentralDispatch:tick(poll_results, lane_dispatch)
  lane_dispatch = lane_dispatch or self.lane_dispatch
  self._fast_tick = self._state ~= STATE_IDLE

  if self._state == STATE_BOUND then
    if not self._bound_machine_id then
      self._state = STATE_IDLE
      self:_reset_stabilizing()
      return {}
    end
    local dbg = lane_dispatch and lane_dispatch:get_lane_debug(self._bound_machine_id)
    if dbg and dbg.state == "idle" then
      if dbg.batch_outcome == "ok" then
        self.log(string.format("[CentralDispatch] batch complete on %s", self._bound_machine_id))
        self._bound_machine_id = nil
        self._state = STATE_IDLE
        self:_reset_stabilizing()
      elseif dbg.batch_outcome == "failed" then
        local now = self.now()
        if now - self._last_fail_log >= 5 then
          self._last_fail_log = now
          self.log(string.format("[CentralDispatch] handoff failed on %s: %s — retry assign",
            self._bound_machine_id, tostring(dbg.last_error)))
        end
        self._bound_machine_id = nil
        self._state = STATE_ASSIGN
      end
    end
    return {}
  end

  local adapter, adapter_err = self:_item_adapter()
  local side = self:_adapter_side()
  if not adapter or type(side) ~= "number" then
    if self._state ~= STATE_IDLE then
      self._state = STATE_IDLE
      self:_reset_stabilizing()
    end
    return {}
  end

  local fp = self:_item_fingerprint(adapter, side)
  local has_items = self:_fingerprint_nonempty(fp)

  if self._state == STATE_IDLE then
    if not has_items then return {} end
    if not self:_central_admission_ok(adapter, side) then return {} end
    self._fingerprint = fp
    self._stable_since = self.now()
    self._state = STATE_STABILIZING
    self._stabilize_logged = false
    self._fast_tick = true
    self.log("[CentralDispatch] items in central chest → stabilizing")
    return { { type = "central_buffer_ready", detail = "items in central chest" } }
  end

  if self._state == STATE_STABILIZING then
    self._fast_tick = true
    if not has_items then
      self._state = STATE_IDLE
      self:_reset_stabilizing()
      return {}
    end
    if not self:_central_admission_ok(adapter, side) then return {} end

    if not fingerprint_equal(fp, self._fingerprint) then
      self._fingerprint = fp
      self._stable_since = self.now()
      self._stabilize_logged = false
      return {}
    end

    local stable_for = self.now() - self._stable_since
    if stable_for < self:_stabilize_s() then
      if not self._stabilize_logged then
        self._stabilize_logged = true
        self.log(string.format("[CentralDispatch] stabilizing (%.1fs / %.1fs)",
          stable_for, self:_stabilize_s()))
      end
      return {}
    end

    self._state = STATE_ASSIGN
    self.log(string.format("[CentralDispatch] stable %.1fs → assign", stable_for))
  end

  if self._state == STATE_ASSIGN then
    self._fast_tick = true
    if not has_items then
      self._state = STATE_IDLE
      self:_reset_stabilizing()
      return {}
    end

    local machine, idx, stage_detail = self:find_handoff_target_rr(
      self.config.machines, poll_results, lane_dispatch)
    if not machine then
      local now = self.now()
      if now - self._last_wait_log >= 5 then
        self._last_wait_log = now
        if stage_detail then
          self.log(string.format("[CentralDispatch] CENTRAL_WAIT_STAGING — %s", tostring(stage_detail)))
        else
          self.log("[CentralDispatch] CENTRAL_WAIT_OUTPUT — no available machine")
        end
      end
      return { { type = "central_wait_output", detail = "all lanes busy or not empty" } }
    end

    local manifest = self:_batch_manifest(adapter, side)
    if #manifest.items == 0 and #manifest.fluids == 0 then
      return { { type = "central_wait_output", detail = "central chest empty after stabilize" } }
    end

    if lane_dispatch and lane_dispatch.handoff_from_central then
      local ok, handoff_err = lane_dispatch:handoff_from_central(machine, manifest)
      if not ok then
        local now = self.now()
        if now - self._last_handoff_log >= 5 then
          self._last_handoff_log = now
          self.log(string.format("[CentralDispatch] handoff deferred %s: %s",
            machine.id, tostring(handoff_err)))
        end
        return { { type = "central_wait_staging", detail = tostring(handoff_err) } }
      end
    end

    self._bound_machine_id = machine.id
    self._state = STATE_BOUND
    self:_advance_rr_after_assign(idx, #self.config.machines)
    self:_reset_stabilizing()
    self.log(string.format("[CentralDispatch] assigned → %s (RR idx %d)", machine.id, idx))
    return {
      { type = "central_staged", machine_id = machine.id, detail = "handoff → " .. machine.id },
    }
  end

  return {}
end

return CentralDispatch
