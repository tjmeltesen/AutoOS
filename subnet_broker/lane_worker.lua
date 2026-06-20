--[[
  AutoOS — Lane Worker (Event-Driven Coroutine)

  Each lane is its own coroutine.  This function is the coroutine body.
  It consumes a pre-built Job Object from the Dispatcher and executes
  it end-to-end.

  Phase: stock → wait_delivery → transfer → wait_dual_if_empty → cleanup+pulse
          → wait_complete → extract → wait_import

  Fluid transfer is handled by an external device; the lane worker only
  moves items through the item transposer.  Cleanup fires when the dual
  IF pull face is empty (adapter sees no items left).

  Constraints:
    - NEVER call component.proxy() — all proxies come from registry
    - All component calls wrapped in pcall()
    - Yield at least once per "step"
]]

local LaneSides = require("lane_sides")
local FluidTanks = require("fluid_tanks")

local LaneWorker = {}

local PULL_SCAN_MAX = 54

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

--- Item stack comparison (matches lane_dispatch:_stack_matches).
local function stack_matches(st, want)
  if type(st) ~= "table" then return false end
  if want.name and st.name ~= want.name then return false end
  if want.damage ~= nil and (st.damage or 0) ~= want.damage then return false end
  if want.label and st.label then
    return tostring(st.label):lower() == tostring(want.label):lower()
  end
  return (st.size or 0) > 0
end

--- Safe slot size query (both getStackInSlot and getSlotStackSize fallback).
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

--- Max slot index to scan (dual IF may report getInventorySize=0).
local function pull_scan_max(tp, side)
  if not tp or not tp.getInventorySize then return PULL_SCAN_MAX end
  local ok, n = pcall(tp.getInventorySize, side)
  return ok and type(n) == "number" and n > 0 and n or PULL_SCAN_MAX
end

--- Build an ordered queue from the manifest if not pre-built.
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

--- Configure one item slot on the ME interface.
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
  local ok, err = pcall(iface.setInterfaceConfiguration, slot, db_address, db_slot, count or 1)
  if not ok then return false, tostring(err) end
  if err == false then return false, "setInterfaceConfiguration returned false" end
  return true
end

--- Configure one fluid config on the ME interface for a given side.
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
  local ok, err = pcall(iface.setFluidInterfaceConfiguration, side, db_address, db_slot)
  if not ok then return false, tostring(err) end
  if err == false then return false, "setFluidInterfaceConfiguration returned false" end
  return true
end

--- Clear one item configuration slot (no-args call = unconfigure).
local function clear_item_slot(iface, slot)
  pcall(iface.setInterfaceConfiguration, slot)
end

--- Clear fluid configs on a given side.
local function clear_fluid_slot(iface, side)
  pcall(iface.setFluidInterfaceConfiguration, side)
end

---------------------------------------------------------------------------
-- Transfer helpers
---------------------------------------------------------------------------

--- Check if the pull face has any items.
local function pull_face_has_items(item_tp, machine)
  local side = LaneSides.central_item_pull_side(machine)
  local start = machine.chest_slot_start or 1
  local size = pull_scan_max(item_tp, side)
  for slot = start, size do
    if safe_slot_size(item_tp, side, slot) > 0 then return true end
  end
  return false
end

--- Check if a specific item step is visible on the pull face.
local function step_visible(item_tp, machine, step)
  local side = LaneSides.central_item_pull_side(machine)
  local start = machine.chest_slot_start or 1
  local size = pull_scan_max(item_tp, side)
  for slot = start, size do
    local ok_s, st = pcall(item_tp.getStackInSlot, side, slot)
    if ok_s and stack_matches(st, step) and (st and st.size or 0) > 0 then
      return true
    end
  end
  return false
end

--- Transfer one matching item step from pull face to bus.
local function transfer_item_step(item_tp, machine, step)
  local from_side = LaneSides.central_item_pull_side(machine)
  local to_side = LaneSides.bus_side(machine)
  local start = machine.chest_slot_start or 1
  local size = pull_scan_max(item_tp, from_side)
  for slot = start, size do
    local ok_s, st = pcall(item_tp.getStackInSlot, from_side, slot)
    if ok_s and stack_matches(st, step) then
      local count = math.max(1, math.min(step.count or (st.size or 1), st.size or 1))
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
  local size = pull_scan_max(item_tp, bus_side)
  for slot = 1, size do
    if slot ~= circuit_slot and safe_slot_size(item_tp, bus_side, slot) > 0 then
      return false
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Wait helper
---------------------------------------------------------------------------

--- Yield once per scheduler tick, re-checking a condition each cycle.
local function await_delivery(registry, item_tp, condition_fn,
                              timeout_s, start_time, phase_name)
  local now_fn = registry.get_now()
  local deadline = start_time + timeout_s

  while true do
    local ok_cond, result = pcall(condition_fn)
    if ok_cond and result then return true end

    if now_fn() >= deadline then
      return false, phase_name .. " timeout after " .. tostring(timeout_s) .. "s"
    end

    coroutine.yield({ type = "yield" })
  end
end

---------------------------------------------------------------------------
-- Main execution
---------------------------------------------------------------------------

--- Execute a pre-built Job Object on one lane.
---@param registry table
---@param job table  Pre-built Job Object with manifest.{items,fluids,queue}
---@param machine_id string
---@return table { status = "done"|"failed", error = string|nil }
function LaneWorker.execute(registry, job, machine_id, event)
  local machine = registry.get_machine(machine_id)
  if not machine then
    return { status = "failed", error = "machine not found: " .. tostring(machine_id) }
  end

  local config = registry.get_config()
  local now_fn = registry.get_now()
  local log = registry._log or function() end

  local item_tp = machine.item_tp or registry.get_transposer(machine.item_transposer_address)
  local iface = machine.iface
  local circuit_mgr = registry.get_circuit_manager()

  local interface_wait_s = (config.central and config.central.interface_wait_s)
    or config.staging_timeout_s or 60
  local staging_timeout_s = config.staging_timeout_s or 60
  local circuit_bus_slot = config.circuit_bus_slot or 1
  local slot_start = machine.interface_item_slot_start or config.interface_item_slot_start or 1
  local queue = build_queue(job.manifest)
  local cfg_slots = {}

  local function fail(err)
    log("[LaneWorker] " .. machine_id .. " FAILED: " .. tostring(err))
    for _, s in ipairs(cfg_slots) do
      if s.fluid then
        clear_fluid_slot(iface, s.side)
      else
        clear_item_slot(iface, s.slot)
      end
      coroutine.yield({ type = "yield" })
    end
    return { status = "failed", error = err }
  end

  ---------------------------------------------------------------------------
  -- Phase 1: Stock the ME interface
  ---------------------------------------------------------------------------
  do
    local item_idx = 0
    local used_sides = {}
    local function next_fluid_side()
      local candidates = {0, 1, 3, 5, 2, 4}
      for _, s in ipairs(candidates) do
        if not used_sides[s] then used_sides[s] = true; return s end
      end
      return nil
    end

    for _, step in ipairs(queue) do
      if step.kind == "fluid" then
        local side = next_fluid_side()
        if not side then return fail("no free interface sides for fluid: " .. tostring(step.fluid_label or "?")) end
        if not iface then return fail("no ME interface for fluid stock") end
        local ok, err = stock_fluid_slot(iface, side, step.db_address, step.db_slot)
        if not ok then return fail("fluid stock side " .. side .. ": " .. tostring(err)) end
        cfg_slots[#cfg_slots + 1] = { fluid = true, side = side }
      else
        item_idx = item_idx + 1
        local iface_slot = slot_start + item_idx - 1
        if not iface then return fail("no ME interface for item stock") end
        local ok, err = stock_item_slot(iface, iface_slot, step.db_address,
          step.db_slot, step.count or 1)
        if not ok then return fail("item stock slot " .. iface_slot .. ": " .. tostring(err)) end
        cfg_slots[#cfg_slots + 1] = { slot = iface_slot }
      end
      coroutine.yield({ type = "yield" })
    end

    -- Fill remaining free sides with duplicate fluid configs.
    -- Only duplicate fluids that need it: >16000mb (central tank) or
    -- nil amount (chest drops — unknown size, assume large).
    -- Low-volume fluids get one side only.
    local fluid_steps = {}
    for _, step in ipairs(queue) do
      if step.kind == "fluid" then
        local amount = step.fluid_amount_mb
        if amount == nil or amount > 16000 then
          fluid_steps[#fluid_steps + 1] = step
        end
      end
    end
    if #fluid_steps > 0 then
      local dup_idx = 0
      local side = next_fluid_side()
      while side do
        dup_idx = dup_idx + 1
        local step = fluid_steps[(dup_idx - 1) % #fluid_steps + 1]
        local ok, err = stock_fluid_slot(iface, side, step.db_address, step.db_slot)
        if not ok then
          log("[LaneWorker] " .. machine_id .. " duplicate fluid stock side " .. side .. " failed: " .. tostring(err))
        else
          cfg_slots[#cfg_slots + 1] = { fluid = true, side = side }
        end
        coroutine.yield({ type = "yield" })
        side = next_fluid_side()
      end
    end
  end

  log("[LaneWorker] " .. machine_id .. " stocked " .. #cfg_slots .. " interface slot(s)")

  ---------------------------------------------------------------------------
  -- Phase 2: Wait for AE2 delivery (items only — fluid device handles itself)
  ---------------------------------------------------------------------------
  if not item_tp then
    return fail("item transposer proxy unavailable")
  end

  do
    local delivery_start = now_fn()
    local function delivery_ready()
      for _, step in ipairs(queue) do
        if step.kind == "item" and not step_visible(item_tp, machine, step) then
          return false
        end
      end
      return true
    end

    local ok_del, del_err = await_delivery(registry, item_tp,
      delivery_ready, interface_wait_s, delivery_start, "delivery")
    if not ok_del then return fail(del_err) end
  end

  ---------------------------------------------------------------------------
  -- Phase 3: Transfer items through transposer to machine input bus
  ---------------------------------------------------------------------------
  do
    for _, step in ipairs(queue) do
      if step.kind ~= "item" then goto continue_item end
      local item_deadline = now_fn() + staging_timeout_s
      local moved_total = 0
      while moved_total < (step.count or 1) do
        local moved, _ = transfer_item_step(item_tp, machine, step)
        if moved and moved >= 1 then
          moved_total = moved_total + moved
        else
          if not step_visible(item_tp, machine, step) then break end
          coroutine.yield({ type = "yield" })
        end
        if now_fn() >= item_deadline then
          return fail("item transfer timeout for " .. tostring(step.name or "?"))
        end
      end
      ::continue_item::
    end
  end

  log("[LaneWorker] " .. machine_id .. " transfer complete")

  ---------------------------------------------------------------------------
  -- Phase 4: Wait for dual IF pull face to empty, then cleanup + pulse
  ---------------------------------------------------------------------------
  do
    local drain_start = now_fn()
    local function pull_face_empty()
      return not pull_face_has_items(item_tp, machine)
    end

    local ok_drain, drain_err = await_delivery(registry, item_tp,
      pull_face_empty, staging_timeout_s, drain_start, "dual_if_drain")
    if not ok_drain then return fail(drain_err) end

    -- Clear item configs first (items are done when pull face is empty)
    local has_fluid_cfgs = false
    for _, s in ipairs(cfg_slots) do
      if s.fluid then
        has_fluid_cfgs = true
      else
        clear_item_slot(iface, s.slot)
      end
      coroutine.yield({ type = "yield" })
    end

    -- Wait for fluid buffer to drain before clearing fluid configs.
    -- Fluids export asynchronously via AE2 — clearing the config
    -- mid-export kills delivery.
    if has_fluid_cfgs then
      -- ponytail: no fluid transposer in this topology.  The item transposer
      -- exposes getTankLevel on all sides; use it to watch the fluid buffer
      -- drain (external mechanism handles the actual fluid transfer).
      local fluid_buffer_side = LaneSides.central_fluid_pull_side(machine)
      local fluid_drain_start = now_fn()
      local function fluid_buffer_empty()
        return FluidTanks.buffer_empty(item_tp, fluid_buffer_side)
      end
      local ok_fluid, fluid_err = await_delivery(registry, item_tp,
        fluid_buffer_empty, staging_timeout_s, fluid_drain_start, "fluid_drain")
      if not ok_fluid then return fail(fluid_err) end

      -- Now clear fluid configs
      for _, s in ipairs(cfg_slots) do
        if s.fluid then
          clear_fluid_slot(iface, s.side)
        end
        coroutine.yield({ type = "yield" })
      end
    end

    -- Pulse redstone to ungate central buffer
    local redstone_addr = config.redstone_address
    if redstone_addr and redstone_addr ~= "" then
      local rs = registry.get_redstone(redstone_addr)
      if rs and rs.setOutput then
        local rs_side = config.redstone_side or 0
        local pulse_s = config.redstone_pulse_s or 0.1
        pcall(rs.setOutput, rs_side, 15)
        coroutine.yield({ type = "sleep", seconds = pulse_s })
        pcall(rs.setOutput, rs_side, 0)
      end
    end
    log("[LaneWorker] " .. machine_id .. " cleanup+pulse done")
  end

  ---------------------------------------------------------------------------
  -- Phase 5: Wait for machine to finish processing
  ---------------------------------------------------------------------------
  do
    local complete_start = now_fn()
    local saw_active = false
    local quiet_drained_since = nil
    local completion_mode = config.completion_mode or "both"
    local quiet_failsafe_s = config.completion_quiet_failsafe_s or 5

    local function completion_ready()
      local poll = registry.get_poll_result(machine_id)
      if poll and poll.active then
        saw_active = true
        quiet_drained_since = nil
      end
      local drained = bus_drained(item_tp, machine, circuit_bus_slot)
      if not drained then
        quiet_drained_since = nil
        return false
      end
      if completion_mode == "drain" then return true end

      if not saw_active then
        if poll and not poll.active and not poll.has_work then
          quiet_drained_since = quiet_drained_since or now_fn()
          if now_fn() - quiet_drained_since >= quiet_failsafe_s then
            return true
          end
        else
          quiet_drained_since = nil
        end
        return false
      end

      if completion_mode == "adapter" then
        return poll and not poll.active
      end
      if poll and not poll.active then return true end
      return false
    end

    local completion_timeout = config.completion_timeout_s or staging_timeout_s
    local ok_comp, comp_err = await_delivery(registry, item_tp,
      completion_ready, completion_timeout, complete_start, "completion")
    if not ok_comp then return fail(comp_err) end
  end

  ---------------------------------------------------------------------------
  -- Phase 6: Extract circuit from bus to return slot
  ---------------------------------------------------------------------------
  do
    local bus_side = LaneSides.bus_side(machine)
    local return_side = LaneSides.return_side(machine)
    local return_slot = LaneSides.return_slot(machine)

    if not circuit_mgr then return fail("no circuit manager") end

    local size = safe_slot_size(item_tp, bus_side, circuit_bus_slot)
    if size <= 0 then
      log("[LaneWorker] " .. machine_id .. " no circuit on bus, skipping extract")
    else
      local moved, err = circuit_mgr:transfer_one(item_tp, bus_side, return_side,
        circuit_bus_slot, return_slot)
      if not moved or moved < 1 then
        return fail("circuit extract: " .. tostring(err or "transfer failed"))
      end
      coroutine.yield({ type = "yield" })
    end

    -------------------------------------------------------------------------
    -- Phase 7: Wait for circuit import (return slot empties)
    -------------------------------------------------------------------------
    local import_start = now_fn()
    local function import_ready()
      if return_slot then
        return safe_slot_size(item_tp, return_side, return_slot) == 0
      end
      local size = pull_scan_max(item_tp, return_side)
      for slot = 1, size do
        if safe_slot_size(item_tp, return_side, slot) > 0 then return false end
      end
      return true
    end

    local ok_imp, imp_err = await_delivery(registry, item_tp,
      import_ready, staging_timeout_s, import_start, "import")
    if not ok_imp then return fail(imp_err) end
  end

  log("[LaneWorker] " .. machine_id .. " job " .. tostring(job.id) .. " done")
  return { status = "done" }
end

return LaneWorker
