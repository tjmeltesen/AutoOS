--[[
  AutoOS — Lane Context (shared helpers + context builder)
  Extracted from lane_worker.lua.  Every phase function receives a ctx table
  that carries all shared state — no metatable inheritance needed.
]]

local LaneSides = require("lane_sides")
local FluidTanks = require("fluid_tanks")
local HW = require("hw")
local FaultNet = require("fault_net")

local LaneContext = {}

local Logger = require("logger")

-- Phase transition ring buffer (50 entries, shared across all lanes)
local PHASE_RING = { entries = {}, head = 1, count = 0, max = 50 }

local PULL_SCAN_MAX = 54

---------------------------------------------------------------------------
-- Internal helpers (stateless — only touch passed-in values)
---------------------------------------------------------------------------

--- Item stack comparison.
local function stack_matches(st, want)
  if type(st) ~= "table" then return false end
  if want.name and st.name ~= want.name then return false end
  if want.damage ~= nil and (st.damage or 0) ~= want.damage then return false end
  if want.label and st.label then
    return tostring(st.label):lower() == tostring(want.label):lower()
  end
  return (st.size or 0) > 0
end

--- Safe slot size query.
local function safe_slot_size(tp, side, slot)
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

--- Max slot index to scan.
local function pull_scan_max(tp, side)
  if not tp or not tp.getInventorySize then return PULL_SCAN_MAX end
  local ok, n = pcall(tp.getInventorySize, side)
  return ok and type(n) == "number" and n > 0 and n or PULL_SCAN_MAX
end

--- Build ordered queue from manifest.
local function build_queue(manifest)
  local queue = manifest.queue
  if type(queue) == "table" and #queue > 0 then return queue end
  queue = {}
  for _, it in ipairs(manifest.items or {}) do
    queue[#queue + 1] = { kind = "item", name = it.name, damage = it.damage,
      label = it.label, count = it.count, db_slot = it.db_slot, db_address = it.db_address }
  end
  for _, fl in ipairs(manifest.fluids or {}) do
    queue[#queue + 1] = { kind = "fluid", fluid_label = fl.fluid_label,
      fluid_registry = fl.fluid_registry, db_slot = fl.db_slot, db_address = fl.db_address }
  end
  return queue
end

---------------------------------------------------------------------------
-- Stocking helpers
---------------------------------------------------------------------------

local function stock_item_slot(iface, slot, db_address, db_slot, count)
  if not db_address or db_address == "" then
    return false, "db_address is nil/empty — item not in database"
  end
  if type(db_slot) ~= "number" then
    return false, "db_slot is nil — item not in database"
  end
  if not iface or not iface.setInterfaceConfiguration then
    return false, "no setInterfaceConfiguration on interface"
  end
  local ok, ret = pcall(iface.setInterfaceConfiguration, slot, db_address, db_slot, count or 1)
  if not ok then return false, tostring(ret) end
  if ret == false or ret == nil then
    return false, string.format("setInterfaceConfiguration returned %s", tostring(ret))
  end
  return true
end

local function stock_fluid_slot(iface, side, db_address, db_slot)
  if not db_address or db_address == "" then
    return false, "db_address is nil/empty — fluid not in database"
  end
  if type(db_slot) ~= "number" then
    return false, "db_slot is nil — fluid not in database"
  end
  if not iface or not iface.setFluidInterfaceConfiguration then
    return false, "no setFluidInterfaceConfiguration on interface"
  end
  local ok, ret = pcall(iface.setFluidInterfaceConfiguration, side, db_address, db_slot)
  if not ok then return false, tostring(ret) end
  if ret == false or ret == nil then
    return false, string.format("setFluidInterfaceConfiguration returned %s", tostring(ret))
  end
  return true
end

local function clear_item_slot(iface, slot)
  pcall(iface.setInterfaceConfiguration, slot)
end

local function clear_fluid_slot(iface, side)
  pcall(iface.setFluidInterfaceConfiguration, side)
end

---------------------------------------------------------------------------
-- Transfer helpers
---------------------------------------------------------------------------

local function pull_face_has_items(item_tp, machine)
  local side = LaneSides.central_item_pull_side(machine)
  local stacks = HW.get_all_stacks(item_tp, side)
  local count = 0
  for _ in pairs(stacks) do
    count = count + 1
    if count % 10 == 0 then coroutine.yield({ type = "sleep", seconds = 0 }) end
    return true
  end
  return false
end

local function step_visible(item_tp, machine, step)
  local side = LaneSides.central_item_pull_side(machine)
  local stacks = HW.get_all_stacks(item_tp, side)
  local count = 0
  for _, st in pairs(stacks) do
    count = count + 1
    if count % 10 == 0 then coroutine.yield({ type = "sleep", seconds = 0 }) end
    if stack_matches(st, step) then return true end
  end
  return false
end

--- Transfer one matching item step from pull face to bus.
--- @param target_slot number|nil  if set, try to place into this specific bus slot
local function transfer_item_step(item_tp, machine, step, target_slot)
  local from_side = LaneSides.central_item_pull_side(machine)
  local to_side = LaneSides.bus_side(machine)
  local stacks = HW.get_all_stacks(item_tp, from_side)
  for slot, st in pairs(stacks) do
    if stack_matches(st, step) then
      local count = math.max(1, math.min(step.count or (st.size or 1), st.size or 1))
      if target_slot then
        local ok, moved = pcall(item_tp.transferItem, from_side, to_side, count, slot, target_slot)
        if ok and moved and moved >= 1 then return moved, slot end
      end
      local ok, moved = pcall(item_tp.transferItem, from_side, to_side, count, slot)
      if ok and moved and moved >= 1 then return moved, slot end
      ok, moved = pcall(item_tp.transferItem, from_side, to_side, 1, slot)
      if ok and moved and moved >= 1 then return moved, slot end
    end
  end
  return 0
end

--- Bus empty except circuit slot.
local function bus_drained(item_tp, machine, circuit_slot)
  local bus_side = LaneSides.bus_side(machine)
  local stacks = HW.get_all_stacks(item_tp, bus_side)
  local count = 0
  for slot in pairs(stacks) do
    count = count + 1
    if count % 10 == 0 then coroutine.yield({ type = "sleep", seconds = 0 }) end
    if slot ~= circuit_slot then return false end
  end
  return true
end

---------------------------------------------------------------------------
-- Wait helper
---------------------------------------------------------------------------

local function await_delivery(ctx, condition_fn, timeout_s, start_time, phase_name)
  local deadline = start_time + timeout_s
  local crash_streak = 0
  local MAX_CRASH_STREAK = 3  -- ponytail: fail fast, full watchdog if this proves too aggressive
  while true do
    local ok_cond, result = pcall(condition_fn)
    if ok_cond and result then
      crash_streak = 0
      return true
    end
    if not ok_cond then
      crash_streak = crash_streak + 1
      local err_str = tostring(result or "unknown")
      ctx:log(string.format("[LaneWorker] %s %s condition_fn CRASH #%d: %s",
        ctx.machine_id, phase_name, crash_streak, err_str))
      if crash_streak >= MAX_CRASH_STREAK then
        return false, phase_name .. " condition_fn crashed " .. crash_streak .. " times: " .. err_str
      end
    end
    if ctx.now_fn() >= deadline then
      return false, phase_name .. " timeout after " .. tostring(timeout_s) .. "s"
    end
    coroutine.yield({ type = "sleep", seconds = 0 })
  end
end

---------------------------------------------------------------------------
-- Context builder
---------------------------------------------------------------------------

--- Build a lane context table that carries all shared state.
--- This IS the "base class" — every phase function receives it as its sole argument.
---@param registry table
---@param job table
---@param machine_id string
---@return table|nil ctx
function LaneContext.build(registry, job, machine_id)
  local machine = registry.get_machine(machine_id)
  if not machine then return nil end

  local config = registry.get_config()
  local now_fn = registry.get_now()
  local parent_log = registry._log or function() end
  local item_tp = machine.item_tp or registry.get_transposer(machine.item_transposer_address)
  local iface = machine.iface
  local circuit_mgr = registry.get_circuit_manager()

  local ctx = {
    -- Injected references
    registry = registry,
    config = config,
    job = job,
    machine_id = machine_id,
    machine = machine,
    now_fn = now_fn,
    item_tp = item_tp,
    iface = iface,
    circuit_mgr = circuit_mgr,

    -- Derived config values
    interface_wait_s = (config.central and config.central.interface_wait_s)
      or config.staging_timeout_s or 60,
    staging_timeout_s = config.staging_timeout_s or 60,
    circuit_bus_slot = config.circuit_bus_slot or 1,
    slot_start = machine.interface_item_slot_start
      or config.interface_item_slot_start or 1,
    circuit_item_name = config.circuit_item_name
      or "gregtech:gt.integrated_circuit",

    -- Built during execution
    queue = build_queue(job.manifest),
    cfg_slots = {},

    -- Internal functions (exposed so phase modules don't need to re-require)
    _parent_log = parent_log,

    -- Shared diagnostics ring
    _phase_ring = PHASE_RING,
  }

  -- Methods

  function ctx:log(msg)
    parent_log(msg)
    Logger.lane(string.format("[%s] %s", machine_id, msg))
  end

  function ctx:flush_log()
    Logger.flush("lane")
  end

  function ctx:record_phase(phase, event)
    local entry = {
      ts = self.now_fn(),
      machine_id = self.machine_id,
      job_id = self.job and self.job.id,
      phase = phase,
      event = event,
      elapsed_s = self._phase_start and (self.now_fn() - self._phase_start) or 0,
    }
    local ring = self._phase_ring
    ring.entries[ring.head] = entry
    ring.head = (ring.head % ring.max) + 1
    ring.count = math.min(ring.count + 1, ring.max)
    if event == "enter" then
      self._phase_start = self.now_fn()
    end
    Logger.lane(string.format("[PHASE] %s job=%s phase=%s event=%s elapsed=%.3f",
      tostring(self.machine_id), tostring(self.job and self.job.id),
      tostring(phase), tostring(event), entry.elapsed_s))
  end

  --- Clean up interface configs and return false, error.
  --- Phase modules call this and propagate the return.
  function ctx:fail(err)
    local err_str = tostring(err)
    self:log("[LaneWorker] " .. machine_id .. " FAILED: " .. err_str)
    Logger.flush("lane")
    -- Capture into fault_net so it appears in fault.log (unbuffered)
    FaultNet.capture(ctx, "lane." .. machine_id, err_str, { job = job.id })
    for _, s in ipairs(self.cfg_slots) do
      if s.fluid then
        clear_fluid_slot(iface, s.side)
      else
        clear_item_slot(iface, s.slot)
      end
      coroutine.yield({ type = "sleep", seconds = 0 })
    end
    return false, err
  end

  return ctx
end

---------------------------------------------------------------------------
-- Exported helpers — phase modules call these via lane_context
---------------------------------------------------------------------------

LaneContext.stack_matches = stack_matches
LaneContext.safe_slot_size = safe_slot_size
LaneContext.pull_scan_max = pull_scan_max
LaneContext.build_queue = build_queue
LaneContext.stock_item_slot = stock_item_slot
LaneContext.stock_fluid_slot = stock_fluid_slot
LaneContext.clear_item_slot = clear_item_slot
LaneContext.clear_fluid_slot = clear_fluid_slot
LaneContext.pull_face_has_items = pull_face_has_items
LaneContext.step_visible = step_visible
LaneContext.transfer_item_step = transfer_item_step
LaneContext.bus_drained = bus_drained
LaneContext.await_delivery = await_delivery
LaneContext.get_phase_ring = function() return PHASE_RING end

return LaneContext
