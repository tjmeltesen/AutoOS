--[[
  AutoOS — Per-lane LCR dispatch FSM (v1: dual transposer, per_lane)

  Phases: idle -> settle -> transfer -> wait_complete -> extract -> wait_import -> idle
  LCR reference: references/LCR Universal Automation.lua
]]

local HW = require("hw")
local LaneSides = require("lane_sides")
local FluidTanks = require("fluid_tanks")

local LaneDispatch = {}
LaneDispatch.__index = LaneDispatch

local STATE_IDLE = "idle"
local STATE_SETTLE = "settle"
local STATE_QUEUE = "queue"
local STATE_TRANSFER = "transfer"
local STATE_WAIT_COMPLETE = "wait_complete"
local STATE_EXTRACT = "extract"
local STATE_WAIT_IMPORT = "wait_import"
local STATE_FAULTED = "faulted"

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
  self.interface_stock = deps.interface_stock
  self.log = deps.log or function() end
  self.now = deps.now or function() return 0 end
  self.yield_now = deps.yield_now or function() end
  self.yield_sleep = deps.yield_sleep or deps.sleep or function() end
  self.monitor_poll_s = deps.monitor_poll_s or self.config.monitor_poll_s or 0.15
  self.staging_timeout_s = deps.staging_timeout_s or self.config.staging_timeout_s or 60
  self.settle_s = deps.settle_s or self.config.settle_s or 0.1
  self.central_settle_s = deps.central_settle_s
    or (self.config.central and self.config.central.settle_s)
    or self.config.central_settle_s
    or 0
  self.completion_mode = deps.completion_mode or self.config.completion_mode or "both"
  self.circuit_bus_slot = self.config.circuit_bus_slot or 1
  self.transfer_scan_budget = deps.transfer_scan_budget or self.config.transfer_scan_budget or 64
  self.completion_quiet_failsafe_s = deps.completion_quiet_failsafe_s
    or self.config.completion_quiet_failsafe_s
    or 5
  self._lanes = {}
  self._rr_index = 1
  self._locks = {}
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
    staging_manifest = nil,
    active_interface_configs = nil,
    stocked = false,
    item_steps = {},
    fluid_steps = {},
    item_idx = 1,
    fluid_idx = 1,
    item_phase = "idle",
    fluid_phase = "idle",
    item_active_stock = nil,
    fluid_active_stock = nil,
    item_deadline = now + deadline_s,
    fluid_deadline = now + deadline_s,
    transfer_item_slot = nil,
    transfer_item_retry = 1,
    transfer_moved_items = false,
    transfer_moved_fluids = false,
    wait_quiet_since = nil,
    wait_last_signal = nil,
    job = nil,
    job_id = nil,
    attempt = 1,
    state_entered_at = now,
    locked_resources = {},
    last_traceback = nil,
    faulted = false,
  }
end

local function _stack_matches(st, want)
  if type(st) ~= "table" then return false end
  if want.name and st.name ~= want.name then return false end
  if want.damage ~= nil and (st.damage or 0) ~= want.damage then return false end
  if want.label and st.label then
    return tostring(st.label):lower() == tostring(want.label):lower()
  end
  return (st.size or 0) > 0
end

local function _build_steps(manifest)
  local item_steps, fluid_steps = {}, {}
  manifest = manifest or {}
  local queue = manifest.queue
  if type(queue) == "table" and #queue > 0 then
    for _, step in ipairs(queue) do
      if step.kind == "fluid" then
        fluid_steps[#fluid_steps + 1] = step
      else
        item_steps[#item_steps + 1] = step
      end
    end
  else
    for _, it in ipairs(manifest.items or {}) do
      item_steps[#item_steps + 1] = {
        kind = "item",
        slot = it.slot,
        name = it.name,
        damage = it.damage,
        label = it.label,
        count = it.count,
      }
    end
    for _, fl in ipairs(manifest.fluids or {}) do
      fluid_steps[#fluid_steps + 1] = {
        kind = "fluid",
        fluid_label = fl.fluid_label,
        fluid_registry = fl.fluid_registry,
        fluid_filter = fl.fluid_filter,
      }
    end
  end
  return item_steps, fluid_steps
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
    item_idx = lane.item_idx,
    fluid_idx = lane.fluid_idx,
    item_phase = lane.item_phase,
    fluid_phase = lane.fluid_phase,
    job_id = lane.job_id,
    state_entered_at = lane.state_entered_at,
    locked_resources = lane.locked_resources,
    attempt = lane.attempt,
    last_traceback = lane.last_traceback,
  }
end

function LaneDispatch:handoff_complete(machine_id)
  local lane = self._lanes[machine_id]
  if not lane then return false end
  return lane.state == STATE_WAIT_COMPLETE
    or lane.state == STATE_EXTRACT
    or lane.state == STATE_WAIT_IMPORT
    or (lane.state == STATE_IDLE and lane.batch_outcome == "ok")
end

function LaneDispatch:reset_lane(machine_id)
  local lane = self._lanes[machine_id]
  if lane then self:_cleanup_lane(machine_id, lane, "reset") end
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

function LaneDispatch:is_lane_faulted(machine_id)
  local lane = self._lanes[machine_id]
  return lane and lane.state == STATE_FAULTED
end

function LaneDispatch:consume_finished_job(machine_id)
  local lane = self._lanes[machine_id]
  if not lane or not lane.job then return nil end
  local status = lane.job.status
  if status ~= "done" and status ~= "failed" then return nil end
  local job = lane.job
  lane.job = nil
  lane.job_id = nil
  lane.batch_outcome = nil
  return job
end

function LaneDispatch:watchdog_fault(machine_id, detail)
  local lane = self:_lane(machine_id)
  if lane.state == STATE_IDLE or lane.state == STATE_FAULTED then return false end
  lane.last_error = detail or "watchdog timeout"
  lane.batch_outcome = "failed"
  if lane.job then
    lane.job.status = "failed"
    lane.job.finished_at = self.now()
    lane.job.last_error = lane.last_error
  end
  self:_cleanup_lane(machine_id, lane, "watchdog")
  lane.state = STATE_FAULTED
  lane.faulted = true
  lane.fast_tick = false
  lane.state_entered_at = self.now()
  return true
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

function LaneDispatch:_interface_address(machine)
  local addr = machine and machine.interface_address
  if (not addr or addr == "") and self.config.shared_interface_address and self.config.shared_interface_address ~= "" then
    addr = self.config.shared_interface_address
  end
  return addr
end

function LaneDispatch:_job_resources(machine, job)
  local resources = {}
  local iface = self:_interface_address(machine)
  if iface and iface ~= "" then
    resources[#resources + 1] = "interface:" .. tostring(iface)
    resources[#resources + 1] = "fluid_if:" .. tostring(iface) .. ":" .. tostring(machine.interface_fluid_side or self.config.interface_fluid_side or 0)
  end
  if self.config.database_address and self.config.database_address ~= "" then
    resources[#resources + 1] = "db:" .. tostring(self.config.database_address)
  end
  if machine.item_transposer_address then
    resources[#resources + 1] = "tp:" .. tostring(machine.item_transposer_address)
  end
  if machine.fluid_transposer_address then
    resources[#resources + 1] = "tp:" .. tostring(machine.fluid_transposer_address)
  end
  return resources
end

function LaneDispatch:_acquire_locks(machine_id, resources)
  for _, res in ipairs(resources or {}) do
    local owner = self._locks[res]
    if owner and owner ~= machine_id then
      return false, "locked:" .. tostring(res)
    end
  end
  for _, res in ipairs(resources or {}) do
    self._locks[res] = machine_id
  end
  return true
end

function LaneDispatch:_release_locks(machine_id, lane)
  for _, res in ipairs((lane and lane.locked_resources) or {}) do
    if self._locks[res] == machine_id then self._locks[res] = nil end
  end
  if lane then lane.locked_resources = {} end
end

function LaneDispatch:_cleanup_lane(machine_id, lane, reason)
  if not lane then return end
  self:_release_active_stock(nil, lane)
  self:_release_step_stock(lane.item_active_stock)
  self:_release_step_stock(lane.fluid_active_stock)
  lane.item_active_stock = nil
  lane.fluid_active_stock = nil
  self:_release_locks(machine_id, lane)
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
function LaneDispatch:handoff_from_central(machine, manifest)
  local machine_id = machine.id
  if self:_require_interface_staging() then
    local ok, detail = self:verify_staged_on_interface(machine)
    if not ok then return false, detail end
  end
  local lane = self:_lane(machine_id)
  local now = self.now()
  lane.settle_at = now + self.central_settle_s
  lane.saw_active = false
  lane.staged_ok = false
  lane.last_error = nil
  lane.batch_outcome = nil
  lane.interface_wait_logged = false
  lane.staging_manifest = manifest or { items = {}, fluids = {} }
  lane.item_steps, lane.fluid_steps = _build_steps(lane.staging_manifest)
  lane.item_idx = 1
  lane.fluid_idx = 1
  lane.item_phase = "stock"
  lane.fluid_phase = "stock"
  lane.item_active_stock = nil
  lane.fluid_active_stock = nil
  lane.stocked = false
  lane.active_interface_configs = nil
  lane.deadline = now + self:_central_interface_wait_s()
  lane.item_deadline = lane.deadline
  lane.fluid_deadline = lane.deadline
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

function LaneDispatch:assign_job(machine, job)
  if not machine or not machine.id then return false, "machine required" end
  if not job or type(job.manifest) ~= "table" then return false, "job manifest required" end
  local lane = self:_lane(machine.id)
  if lane.state ~= STATE_IDLE then return false, "lane busy" end
  if lane.faulted or lane.state == STATE_FAULTED then return false, "lane faulted" end

  local resources = self:_job_resources(machine, job)
  local ok_lock, lock_err = self:_acquire_locks(machine.id, resources)
  if not ok_lock then return false, lock_err end
  lane.locked_resources = resources
  lane.job = job
  lane.job_id = job.id
  lane.attempt = job.attempt or 1

  local ok, err = self:handoff_from_central(machine, job.manifest)
  if not ok then
    self:_cleanup_lane(machine.id, lane, "assign failed")
    lane.job = nil
    lane.job_id = nil
    return false, err
  end
  job.status = "running"
  job.machine_id = machine.id
  job.started_at = self.now()
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
    if next_state == STATE_IDLE and lane.state ~= STATE_IDLE then
      if lane.job then
        lane.job.finished_at = self.now()
        lane.job.status = lane.batch_outcome == "ok" and "done" or "failed"
        lane.job.last_error = lane.last_error
      end
      self:_cleanup_lane(machine_id, lane, reason)
    end
    lane.state = next_state
    lane.state_entered_at = self.now()
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
  return FluidTanks.tank_level(tp, side)
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

function LaneDispatch:_manifest_from_pull(item_tp, fluid_tp, machine)
  local manifest = { items = {}, fluids = {} }
  local from_side = self:_item_pull_side(machine)
  local start = self:_chest_start(machine)
  local size = self:_pull_scan_max(item_tp, from_side)
  for slot = start, size do
    local st = item_tp.getStackInSlot and item_tp.getStackInSlot(from_side, slot)
    if type(st) == "table" and (st.size or 0) > 0 then
      manifest.items[#manifest.items + 1] = {
        slot = slot,
        name = st.name,
        damage = st.damage or 0,
        label = st.label,
        count = st.size or 1,
      }
    end
  end
  if fluid_tp and self:_buffer_has_fluid(fluid_tp, machine) then
    manifest.fluids[#manifest.fluids + 1] = {
      fluid_label = machine.fluid_label or machine.fluid_registry or "unknown",
      fluid_registry = machine.fluid_registry,
      fluid_filter = machine.fluid_filter,
    }
  end
  return manifest
end

function LaneDispatch:_release_active_stock(machine, lane)
  if not self.interface_stock or not lane.active_interface_configs then return end
  self.interface_stock:release_batch(lane.active_interface_configs)
  lane.active_interface_configs = nil
  lane.stocked = false
end

function LaneDispatch:_release_step_stock(active)
  if not self.interface_stock or not active then return end
  self.interface_stock:release_batch(active)
end

function LaneDispatch:_item_buffer_empty(item_tp, machine)
  return not self:_buffer_has_items(item_tp, machine)
end

function LaneDispatch:_fluid_buffer_empty(fluid_tp, machine)
  local side = self:_fluid_pull_side(machine)
  return FluidTanks.buffer_empty(fluid_tp, side)
end

function LaneDispatch:_step_item_ready(item_tp, machine, step)
  local from_side = self:_item_pull_side(machine)
  local start = self:_chest_start(machine)
  local size = self:_pull_scan_max(item_tp, from_side)
  for slot = start, size do
    local st = item_tp.getStackInSlot and item_tp.getStackInSlot(from_side, slot)
    if _stack_matches(st, step) then return true end
  end
  return false
end

function LaneDispatch:_step_fluid_ready(fluid_tp, machine, step)
  local from_side = self:_fluid_pull_side(machine)
  if not step or (not step.fluid_label and not step.fluid_registry) then
    return self:_buffer_has_fluid(fluid_tp, machine)
  end
  for _, row in ipairs(FluidTanks.non_empty_tanks(fluid_tp, from_side)) do
    if FluidTanks.label_matches(row.name, step.fluid_label or step.fluid_registry) then
      return true
    end
  end
  return false
end

function LaneDispatch:_transfer_one_item_step(item_tp, machine, step)
  local from_side = self:_item_pull_side(machine)
  local to_side = LaneSides.bus_side(machine)
  local start = self:_chest_start(machine)
  local size = self:_pull_scan_max(item_tp, from_side)
  for slot = start, size do
    local st = item_tp.getStackInSlot and item_tp.getStackInSlot(from_side, slot)
    if _stack_matches(st, step) then
      local count = math.max(1, math.min(step.count or (st.size or 1), st.size or 1))
      local ok, moved = pcall(item_tp.transferItem, from_side, to_side, count, slot)
      if ok and moved and moved >= 1 then return true end
      ok, moved = pcall(item_tp.transferItem, from_side, to_side, 1, slot)
      return ok and moved and moved >= 1
    end
  end
  return false
end

function LaneDispatch:_queue_complete(lane)
  return lane.item_idx > #(lane.item_steps or {}) and lane.fluid_idx > #(lane.fluid_steps or {})
end

function LaneDispatch:_manifest_pull_ready(item_tp, fluid_tp, machine, manifest)
  manifest = manifest or {}
  local items = manifest.items or {}
  local fluids = manifest.fluids or {}
  local from_side = self:_item_pull_side(machine)
  local start = self:_chest_start(machine)
  local size = self:_pull_scan_max(item_tp, from_side)

  for _, want in ipairs(items) do
    local found = false
    for slot = start, size do
      local st = item_tp.getStackInSlot and item_tp.getStackInSlot(from_side, slot)
      if _stack_matches(st, want) then
        found = true
        break
      end
    end
    if not found then return false end
  end

  if #fluids > 0 and not self:_buffer_has_fluid(fluid_tp, machine) then
    return false
  end
  return true
end

function LaneDispatch:_transfer_fluids(fluid_tp, machine)
  local from_side = self:_fluid_pull_side(machine)
  if self:_fluid_level(fluid_tp, from_side) <= 0 then return false, false end
  local to_side = LaneSides.fluid_hatch_side(machine)
  local ok, result = pcall(fluid_tp.transferFluid, from_side, to_side, FLUID_CHUNK)
  if not ok or result == false or result == 0 then return false, false end
  local pending = self:_fluid_level(fluid_tp, from_side) > 0
  if pending then self.yield_now() end
  return true, pending
end

function LaneDispatch:_transfer_items(item_tp, machine, lane)
  local from_side = self:_item_pull_side(machine)
  local to_side = LaneSides.bus_side(machine)
  local start = self:_chest_start(machine)
  local size = self:_pull_scan_max(item_tp, from_side)
  lane = lane or {}
  local slot = lane.transfer_item_slot or start
  local retry = lane.transfer_item_retry or 1
  local moved_any = false
  local scanned = 0

  while slot <= size and scanned < self.transfer_scan_budget do
    local count = self:_slot_size(item_tp, from_side, slot)
    if count > 0 then
      local ok, moved = pcall(item_tp.transferItem, from_side, to_side, count, slot)
      if ok and moved and moved >= 1 then
        moved_any = true
        retry = 1
      else
        ok, moved = pcall(item_tp.transferItem, from_side, to_side, 1, slot)
        if ok and moved and moved >= 1 then
          moved_any = true
          retry = 1
        else
          retry = retry + 1
          if retry <= TRANSFER_RETRIES then
            lane.transfer_item_slot = slot
            lane.transfer_item_retry = retry
            self.yield_sleep(0.05)
            return moved_any, true
          end
          retry = 1
        end
      end
      self.yield_now()
    end
    slot = slot + 1
    scanned = scanned + 1
  end

  if slot <= size then
    lane.transfer_item_slot = slot
    lane.transfer_item_retry = retry
    self.yield_now()
    return moved_any, true
  end

  lane.transfer_item_slot = nil
  lane.transfer_item_retry = 1
  return moved_any, false
end

function LaneDispatch:_fluid_drained(fluid_tp, machine)
  local side = LaneSides.fluid_hatch_side(machine)
  return self:_fluid_level(fluid_tp, side) == 0
end

function LaneDispatch:_item_drained(item_tp, machine)
  local side = LaneSides.bus_side(machine)
  local size = self:_pull_scan_max(item_tp, side)
  for slot = 1, size do
    if slot ~= self.circuit_bus_slot and self:_slot_size(item_tp, side, slot) > 0 then
      return false
    end
  end
  return true
end

function LaneDispatch:_drain_complete(item_tp, fluid_tp, machine)
  local fluid_ok = not fluid_tp or self:_fluid_drained(fluid_tp, machine)
  local item_ok = not item_tp or self:_item_drained(item_tp, machine)
  return fluid_ok and item_ok
end

function LaneDispatch:_wait_signal(poll_status, item_tp, fluid_tp, machine)
  local bus_side = LaneSides.bus_side(machine)
  local hatch_side = LaneSides.fluid_hatch_side(machine)
  return table.concat({
    poll_status and tostring(poll_status.active) or "?",
    poll_status and tostring(poll_status.has_work) or "?",
    poll_status and tostring(poll_status.work_progress) or "?",
    poll_status and tostring(poll_status.work_max_progress) or "?",
    item_tp and tostring(self:_item_drained(item_tp, machine)) or "?",
    fluid_tp and tostring(self:_fluid_level(fluid_tp, hatch_side)) or "?",
    item_tp and tostring(self:_slot_size(item_tp, bus_side, self.circuit_bus_slot)) or "?",
  }, "|")
end

function LaneDispatch:_quiet_drained_for(lane, poll_status, item_tp, fluid_tp, machine)
  if poll_status and (poll_status.active or poll_status.has_work) then
    lane.wait_quiet_since = nil
    lane.wait_last_signal = nil
    return false
  end

  if not self:_drain_complete(item_tp, fluid_tp, machine) then
    lane.wait_quiet_since = nil
    lane.wait_last_signal = nil
    return false
  end

  local now = self.now()
  local signal = self:_wait_signal(poll_status, item_tp, fluid_tp, machine)
  if lane.wait_last_signal ~= signal then
    lane.wait_last_signal = signal
    lane.wait_quiet_since = now
    return false
  end
  lane.wait_quiet_since = lane.wait_quiet_since or now
  return (now - lane.wait_quiet_since) >= self.completion_quiet_failsafe_s
end

function LaneDispatch:_completion_ready(lane, poll_status, item_tp, fluid_tp, machine)
  if poll_status and poll_status.active then
    lane.saw_active = true
  end

  local drained = self:_drain_complete(item_tp, fluid_tp, machine)
  if not drained then return false end

  if not lane.saw_active and self:_quiet_drained_for(lane, poll_status, item_tp, fluid_tp, machine) then
    return true
  end

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

function LaneDispatch:_tick_lane_impl(machine, poll_status)
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

  if lane.state == STATE_FAULTED then
    lane.fast_tick = false
    return false, events
  end

  if lane.state == STATE_IDLE then
    lane.fast_tick = false
    lane.saw_active = false
    lane.stocked = false
    lane.staging_manifest = nil
    lane.active_interface_configs = nil
    lane.item_steps = {}
    lane.fluid_steps = {}
    lane.item_idx = 1
    lane.fluid_idx = 1
    lane.item_phase = "idle"
    lane.fluid_phase = "idle"
    lane.item_active_stock = nil
    lane.fluid_active_stock = nil
    lane.transfer_item_slot = nil
    lane.transfer_item_retry = 1
    lane.transfer_moved_items = false
    lane.transfer_moved_fluids = false
    lane.wait_quiet_since = nil
    lane.wait_last_signal = nil

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
    lane.staging_manifest = self:_manifest_from_pull(itp, ftp, machine)
    lane.stocked = false
    lane.active_interface_configs = nil
    lane.transfer_item_slot = nil
    lane.transfer_item_retry = 1
    lane.transfer_moved_items = false
    lane.transfer_moved_fluids = false
    lane.wait_quiet_since = nil
    lane.wait_last_signal = nil
    self:_transition(machine_id, lane, STATE_SETTLE, "buffer ready")
    events[#events + 1] = { type = "buffer_ready", detail = "inputs detected" }
    return true, events
  end

  if lane.state == STATE_SETTLE then
    lane.fast_tick = true
    if now < lane.settle_at then return true, events end

    if not self:_is_central_mode()
      and self.interface_stock
      and lane.staging_manifest
      and not lane.stocked then
      local ok_stock, stock_err, active_cfg = self.interface_stock:stock_batch(machine, lane.staging_manifest)
      if not ok_stock then
        if active_cfg then self.interface_stock:release_batch(active_cfg) end
        lane.last_error = "interface stock failed: " .. tostring(stock_err)
        lane.batch_outcome = "failed"
        self:_transition(machine_id, lane, STATE_IDLE, "interface stock failed")
        events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
        return false, events
      end
      lane.stocked = true
      lane.active_interface_configs = active_cfg
    end

    if self:_is_central_mode() then
      self:_transition(machine_id, lane, STATE_QUEUE, "settle done")
      return true, events
    end
    self:_transition(machine_id, lane, STATE_TRANSFER, "settle done")
    return true, events
  end

  if lane.state == STATE_QUEUE then
    lane.fast_tick = true
    local itp = ensure_item_tp()
    local ftp = ensure_fluid_tp()
    if not itp or not ftp then
      return true, { { type = "recover_failed", detail = "transposer unavailable" } }
    end

    local item_step = lane.item_steps[lane.item_idx]
    if item_step then
      if lane.item_phase == "stock" then
        if self.interface_stock then
          local ok_stock, stock_err, active = self.interface_stock:stock_one_item(machine, item_step, 1)
          if not ok_stock then
            if active then self:_release_step_stock(active) end
            lane.last_error = "item stock failed: " .. tostring(stock_err)
            lane.batch_outcome = "failed"
            self:_transition(machine_id, lane, STATE_IDLE, "queue item stock failed")
            events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
            return false, events
          end
          lane.item_active_stock = active
        end
        lane.item_deadline = now + self:_central_interface_wait_s()
        lane.item_phase = "wait_buffer"
      elseif lane.item_phase == "wait_buffer" then
        if self:_step_item_ready(itp, machine, item_step) then
          lane.item_phase = "transfer"
        elseif now >= lane.item_deadline then
          lane.last_error = string.format("item track step %d not visible on buffer", lane.item_idx)
          lane.batch_outcome = "failed"
          self:_release_step_stock(lane.item_active_stock)
          lane.item_active_stock = nil
          self:_transition(machine_id, lane, STATE_IDLE, "queue item wait timeout")
          events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
          return false, events
        end
      elseif lane.item_phase == "transfer" then
        if self:_transfer_one_item_step(itp, machine, item_step) then
          lane.item_deadline = now + self.staging_timeout_s
          lane.item_phase = "drain"
        elseif now >= lane.item_deadline then
          lane.last_error = string.format("item track step %d transfer failed", lane.item_idx)
          lane.batch_outcome = "failed"
          self:_release_step_stock(lane.item_active_stock)
          lane.item_active_stock = nil
          self:_transition(machine_id, lane, STATE_IDLE, "queue item transfer failed")
          events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
          return false, events
        end
      elseif lane.item_phase == "drain" then
        if self:_item_buffer_empty(itp, machine) then
          self:_release_step_stock(lane.item_active_stock)
          lane.item_active_stock = nil
          lane.item_idx = lane.item_idx + 1
          lane.item_phase = "stock"
        elseif now >= lane.item_deadline then
          lane.last_error = string.format("item track step %d buffer never emptied", lane.item_idx)
          lane.batch_outcome = "failed"
          self:_release_step_stock(lane.item_active_stock)
          lane.item_active_stock = nil
          self:_transition(machine_id, lane, STATE_IDLE, "queue item drain timeout")
          events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
          return false, events
        end
      end
    end

    local fluid_step = lane.fluid_steps[lane.fluid_idx]
    if fluid_step then
      if lane.fluid_phase == "stock" then
        if self.interface_stock then
          local ok_stock, stock_err, active = self.interface_stock:stock_one_fluid(machine, fluid_step)
          if not ok_stock then
            if active then self:_release_step_stock(active) end
            lane.last_error = "fluid stock failed: " .. tostring(stock_err)
            lane.batch_outcome = "failed"
            self:_transition(machine_id, lane, STATE_IDLE, "queue fluid stock failed")
            events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
            return false, events
          end
          lane.fluid_active_stock = active
        end
        lane.fluid_deadline = now + self:_central_interface_wait_s()
        lane.fluid_phase = "wait_buffer"
      elseif lane.fluid_phase == "wait_buffer" then
        if self:_step_fluid_ready(ftp, machine, fluid_step) then
          lane.fluid_phase = "transfer"
        elseif now >= lane.fluid_deadline then
          lane.last_error = string.format("fluid track step %d (%s) not visible on buffer",
            lane.fluid_idx, tostring(fluid_step.fluid_label or fluid_step.fluid_registry or "?"))
          lane.batch_outcome = "failed"
          self:_release_step_stock(lane.fluid_active_stock)
          lane.fluid_active_stock = nil
          self:_transition(machine_id, lane, STATE_IDLE, "queue fluid wait timeout")
          events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
          return false, events
        end
      elseif lane.fluid_phase == "transfer" then
        local moved, pending = self:_transfer_fluids(ftp, machine)
        if moved then
          if pending then
            return true, events
          end
          lane.fluid_deadline = self.now() + self.staging_timeout_s
          lane.fluid_phase = "drain"
        elseif now >= lane.fluid_deadline then
          lane.last_error = string.format("fluid track step %d (%s) transfer failed",
            lane.fluid_idx, tostring(fluid_step.fluid_label or fluid_step.fluid_registry or "?"))
          lane.batch_outcome = "failed"
          self:_release_step_stock(lane.fluid_active_stock)
          lane.fluid_active_stock = nil
          self:_transition(machine_id, lane, STATE_IDLE, "queue fluid transfer failed")
          events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
          return false, events
        end
      elseif lane.fluid_phase == "drain" then
        if self:_fluid_buffer_empty(ftp, machine) then
          self:_release_step_stock(lane.fluid_active_stock)
          lane.fluid_active_stock = nil
          lane.fluid_idx = lane.fluid_idx + 1
          lane.fluid_phase = "stock"
        elseif now >= lane.fluid_deadline then
          lane.last_error = string.format("fluid track step %d (%s) buffer never emptied",
            lane.fluid_idx, tostring(fluid_step.fluid_label or fluid_step.fluid_registry or "?"))
          lane.batch_outcome = "failed"
          self:_release_step_stock(lane.fluid_active_stock)
          lane.fluid_active_stock = nil
          self:_transition(machine_id, lane, STATE_IDLE, "queue fluid drain timeout")
          events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
          return false, events
        end
      end
    end

    if self:_queue_complete(lane) then
      lane.saw_active = false
      lane.deadline = now + self.staging_timeout_s
      lane.wait_quiet_since = nil
      lane.wait_last_signal = nil
      self:_transition(machine_id, lane, STATE_WAIT_COMPLETE, "queue done")
      events[#events + 1] = { type = "staged", detail = "queue -> machine" }
      return true, events
    end
    return true, events
  end

  if lane.state == STATE_TRANSFER then
    lane.fast_tick = true
    local itp = ensure_item_tp()
    local ftp = ensure_fluid_tp()
    if not itp or not ftp then
      return true, { { type = "recover_failed", detail = "transposer unavailable" } }
    end

    local moved_items, pending_items = self:_transfer_items(itp, machine, lane)
    lane.transfer_moved_items = lane.transfer_moved_items or moved_items
    local moved_fluids, pending_fluids = false, false
    if not pending_items then
      moved_fluids, pending_fluids = self:_transfer_fluids(ftp, machine)
      lane.transfer_moved_fluids = lane.transfer_moved_fluids or moved_fluids
    end
    local needs_fluids = lane.staging_manifest
      and type(lane.staging_manifest.fluids) == "table"
      and #lane.staging_manifest.fluids > 0

    if pending_items or pending_fluids then
      return true, events
    end

    if self:_is_central_mode() and not lane.transfer_moved_items and not lane.transfer_moved_fluids then
      local pull = self:_item_pull_side(machine)
      local detail = self.circuit_manager:describe_face(itp, pull)
      lane.last_error = string.format("no items moved from dual IF side %d (%s)", pull, detail)
      lane.batch_outcome = "failed"
      self:_release_active_stock(machine, lane)
      self:_transition(machine_id, lane, STATE_IDLE, "transfer empty")
      events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
      return false, events
    end
    if self:_is_central_mode() and needs_fluids and not lane.transfer_moved_fluids then
      local from_side = self:_fluid_pull_side(machine)
      lane.last_error = string.format(
        "fluid expected but none moved from side %d (check interface_fluid_side / side_fluid_buffer)",
        from_side
      )
      lane.batch_outcome = "failed"
      self:_release_active_stock(machine, lane)
      self:_transition(machine_id, lane, STATE_IDLE, "transfer missing fluid")
      events[#events + 1] = { type = "recover_failed", detail = lane.last_error }
      return false, events
    end
    self:_release_active_stock(machine, lane)
    lane.transfer_moved_items = false
    lane.transfer_moved_fluids = false
    lane.saw_active = false
    lane.deadline = now + self.staging_timeout_s
    lane.wait_quiet_since = nil
    lane.wait_last_signal = nil
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

function LaneDispatch:tick_lane(machine, poll_status)
  local ok, wants_fast, events = xpcall(function()
    return self:_tick_lane_impl(machine, poll_status)
  end, debug.traceback)
  if ok then return wants_fast, events end

  local machine_id = machine and machine.id or "unknown"
  local lane = self:_lane(machine_id)
  lane.last_traceback = tostring(wants_fast)
  lane.last_error = "lane crash"
  lane.batch_outcome = "failed"
  if lane.job then
    lane.job.status = "failed"
    lane.job.finished_at = self.now()
    lane.job.last_error = lane.last_error
  end
  lane.faulted = true
  self:_cleanup_lane(machine_id, lane, "crash")
  lane.state = STATE_FAULTED
  lane.fast_tick = false
  lane.state_entered_at = self.now()
  self.log(string.format("[LaneDispatch] %s crashed:\n%s", machine_id, tostring(wants_fast)))
  return false, { { type = "recover_failed", detail = "lane crash: " .. tostring(wants_fast) } }
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
