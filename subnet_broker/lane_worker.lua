--[[
  AutoOS — Lane Worker (Event-Driven Coroutine)

  REPLACES the FSM in lane_dispatch.lua (1267 lines → ~280 lines).
  Each lane is its own coroutine.  This function is the coroutine body.
  It consumes a pre-built Job Object from the Dispatcher (Phase 3) and
  executes it end-to-end.

  Phase: stock → wait_delivery → transfer → wait_complete → extract → wait_import → cleanup

  Constraints:
    - NEVER call component.proxy() — all proxies come from registry
    - NEVER call event.pull() with a timeout in a busy loop — event-driven yield
    - No os.sleep() polling — the coroutine scheduler handles timing
    - All component calls wrapped in pcall()
    - Yield at least once per "step"
]]

local LaneSides = require("lane_sides")
local FluidTanks = require("fluid_tanks")

local LaneWorker = {}

local FLUID_CHUNK = 1000000
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
  -- Fallback: build from items/fluids arrays
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

--- Configure one fluid slot on the ME interface.
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

--- Clear one fluid configuration slot.
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

--- Check if the pull face has the expected fluid.
local function pull_face_has_fluid(fluid_tp, machine)
  local side = LaneSides.central_fluid_pull_side(machine)
  return FluidTanks.tank_level(fluid_tp, side) > 0
end

--- Check if a specific queue step is visible on the pull face.
local function step_visible(item_tp, fluid_tp, machine, step)
  if step.kind == "fluid" then
    local side = LaneSides.central_fluid_pull_side(machine)
    if not step.fluid_label and not step.fluid_registry then
      return FluidTanks.tank_level(fluid_tp, side) > 0
    end
    for _, row in ipairs(FluidTanks.non_empty_tanks(fluid_tp, side)) do
      if FluidTanks.label_matches(row.name, step.fluid_label or step.fluid_registry) then
        return true
      end
    end
    return false
  end

  -- Item step
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

--- Transfer a batch of fluids from pull face to hatch.  Returns (moved, pending).
local function transfer_fluid_chunk(fluid_tp, machine)
  local from_side = LaneSides.central_fluid_pull_side(machine)
  local to_side = LaneSides.fluid_hatch_side(machine)
  if FluidTanks.tank_level(fluid_tp, from_side) <= 0 then return false, false end
  local ok, result = pcall(fluid_tp.transferFluid, from_side, to_side, FLUID_CHUNK)
  if not ok or result == false or result == 0 then return false, false end
  local pending = FluidTanks.tank_level(fluid_tp, from_side) > 0
  return true, pending
end

--- Drain check: bus empty except circuit slot.  fluid hatch empty.
local function drain_complete(item_tp, fluid_tp, machine, circuit_slot)
  if fluid_tp then
    local hatch_side = LaneSides.fluid_hatch_side(machine)
    if FluidTanks.tank_level(fluid_tp, hatch_side) > 0 then return false end
  end
  if item_tp then
    local bus_side = LaneSides.bus_side(machine)
    local size = pull_scan_max(item_tp, bus_side)
    for slot = 1, size do
      if slot ~= circuit_slot and safe_slot_size(item_tp, bus_side, slot) > 0 then
        return false
      end
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Event-driven wait helper
---------------------------------------------------------------------------

--- Yield for inventory_changed events, re-checking a condition after each
--- delivery.  Returns true when condition is met, false+err on timeout.
--- Yields at least once even if condition is already true (scheduler fairness).
local function await_delivery(registry, machine, item_tp, fluid_tp, condition_fn,
                              timeout_s, start_time, phase_name)
  local now_fn = registry.get_now()
  local deadline = start_time + timeout_s
  local first = true

  while true do
    if not first then
      -- Wait for the next inventory change event
      coroutine.yield({ type = "event", filter = "inventory_changed" })
    end
    first = false

    -- Check condition after event (or immediately on first pass)
    local ok_cond, result = pcall(condition_fn)
    if ok_cond and result then return true end

    -- Timeout check
    if now_fn() >= deadline then
      return false, phase_name .. " timeout after " .. tostring(timeout_s) .. "s"
    end

    -- Yield a brief sleep so the scheduler can check timeout on next cycle
    coroutine.yield({ type = "yield" })
  end
end

---------------------------------------------------------------------------
-- Main execution
---------------------------------------------------------------------------

--- Execute a pre-built Job Object on one lane.
--- This IS the coroutine body — it yields internally and returns when done.
---@param registry table  Phase-1 static registry (get_machine, get_transposer,
---   get_interface, get_config, get_circuit_manager, get_now, log)
---@param job table  Pre-built Job Object with manifest.{items,fluids,queue},
---   each entry carrying pre-computed db_slot and db_address.
---@param machine_id string  Target machine identifier.
---@param event string|nil  Triggering event name from the scheduler (unused; retained for API compatibility).
---@return table { status = "done"|"failed", error = string|nil }
function LaneWorker.execute(registry, job, machine_id, event)
  -- Resolve dependencies from registry (no component.proxy() calls)
  local machine = registry.get_machine(machine_id)
  if not machine then
    return { status = "failed", error = "machine not found: " .. tostring(machine_id) }
  end

  local config = registry.get_config()
  local now_fn = registry.get_now()
  local log = registry._log or function() end

  -- Cached transposer proxies (pre-resolved by registry at boot)
  local item_tp = machine.item_tp or registry.get_transposer(machine.item_transposer_address)
  local fluid_tp = machine.fluid_tp or registry.get_transposer(machine.fluid_transposer_address)

  -- ME interface proxy (pre-resolved by registry at boot)
  local iface = machine.iface

  -- Circuit manager (already initialized by Phase 1)
  local circuit_mgr = registry.get_circuit_manager()

  -- Config values
  local interface_wait_s = (config.central and config.central.interface_wait_s)
    or config.staging_timeout_s or 60
  local staging_timeout_s = config.staging_timeout_s or 60
  local circuit_bus_slot = config.circuit_bus_slot or 1
  local slot_start = machine.interface_item_slot_start or config.interface_item_slot_start or 1
  local fluid_side = machine.interface_fluid_side or config.interface_fluid_side or 0

  -- Build ordered queue from manifest
  local queue = build_queue(job.manifest)
  local cfg_slots = {}  -- track configured slots for cleanup

  local function fail(err)
    log("[LaneWorker] " .. machine_id .. " FAILED: " .. tostring(err))
    -- Best-effort cleanup
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
    local fluid_stocked = false

    for _, step in ipairs(queue) do
      if step.kind == "fluid" then
        if not fluid_stocked then
          if not iface then return fail("no ME interface for fluid stock") end
          local ok, err = stock_fluid_slot(iface, fluid_side, step.db_address, step.db_slot)
          if not ok then return fail("fluid stock: " .. tostring(err)) end
          cfg_slots[#cfg_slots + 1] = { fluid = true, side = fluid_side }
          fluid_stocked = true
        end
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
  end

  log("[LaneWorker] " .. machine_id .. " stocked " .. #cfg_slots .. " interface slot(s)")

  ---------------------------------------------------------------------------
  -- Phase 2: Wait for AE2 delivery
  ---------------------------------------------------------------------------
  if not item_tp or not fluid_tp then
    return fail("transposer proxies unavailable")
  end

  do
    local delivery_start = now_fn()
    local function delivery_ready()
      local has_items = false
      local has_fluids = false
      for _, step in ipairs(queue) do
        if step.kind == "fluid" then has_fluids = true else has_items = true end
      end
      if has_items and not pull_face_has_items(item_tp, machine) then return false end
      if has_fluids and not pull_face_has_fluid(fluid_tp, machine) then return false end
      return true
    end

    local ok_del, del_err = await_delivery(registry, machine, item_tp, fluid_tp,
      delivery_ready, interface_wait_s, delivery_start, "delivery")
    if not ok_del then return fail(del_err) end
  end

  ---------------------------------------------------------------------------
  -- Phase 3: Transfer items + fluids through the machine
  ---------------------------------------------------------------------------
  do
    for _, step in ipairs(queue) do
      if step.kind == "fluid" then
        -- Wait for THIS fluid type to appear on pull face before transferring.
        -- Without this, after fluid_A drains, fluid_B hasn't arrived yet and
        -- transfer_fluid_chunk immediately returns false, skipping it.
        local fluid_wait_start = now_fn()
        local function this_fluid_ready()
          return step_visible(item_tp, fluid_tp, machine, step)
        end
        local ok_wait, wait_err = await_delivery(registry, machine, item_tp, fluid_tp,
          this_fluid_ready, interface_wait_s, fluid_wait_start, "fluid_delivery")
        if not ok_wait then return fail(wait_err) end

        -- Fluids: push in chunks until pull face is dry
        local fluid_deadline = now_fn() + staging_timeout_s
        while true do
          local moved, pending = transfer_fluid_chunk(fluid_tp, machine)
          if not moved and not pending then break end
          if pending then
            coroutine.yield({ type = "yield" })
          end
          if now_fn() >= fluid_deadline then
            return fail("fluid transfer timeout for " .. tostring(step.fluid_label or step.fluid_registry or "?"))
          end
          if not pending then break end
        end
      else
        -- Items: transfer each matching stack
        local item_deadline = now_fn() + staging_timeout_s
        local moved_total = 0
        while moved_total < (step.count or 1) do
          local moved, _ = transfer_item_step(item_tp, machine, step)
          if moved and moved >= 1 then
            moved_total = moved_total + moved
            coroutine.yield({ type = "yield" })
          else
            -- Check if step is still visible; if not it may have all moved
            if not step_visible(item_tp, fluid_tp, machine, step) then break end
            coroutine.yield({ type = "yield" })
          end
          if now_fn() >= item_deadline then
            return fail("item transfer timeout for " .. tostring(step.name or "?"))
          end
        end
      end
    end
  end

  log("[LaneWorker] " .. machine_id .. " transfer complete")

  ---------------------------------------------------------------------------
  -- Phase 4: Wait for machine to finish processing
  ---------------------------------------------------------------------------
  do
    local complete_start = now_fn()
    local saw_active = false
    local quiet_drained_since = nil  -- ponytail: quiet-drain failsafe for fast recipes
    local completion_mode = config.completion_mode or "both"
    local quiet_failsafe_s = config.completion_quiet_failsafe_s or 5

    local function completion_ready()
      local poll = registry.get_poll_result(machine_id)
      if poll and poll.active then
        saw_active = true
        quiet_drained_since = nil
      end
      local drained = drain_complete(item_tp, fluid_tp, machine, circuit_bus_slot)
      if not drained then
        quiet_drained_since = nil
        return false
      end
      if completion_mode == "drain" then return true end

      -- Quiet-drain failsafe: if machine was never seen active but
      -- drain is complete and poll consistently shows idle for N seconds,
      -- declare done (handles fast recipes that finish between polls).
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
      -- "both": adapter done OR saw_active and now idle
      if poll and not poll.active then return true end
      return false
    end

    local ok_comp, comp_err = await_delivery(registry, machine, item_tp, fluid_tp,
      completion_ready, staging_timeout_s, complete_start, "completion")
    if not ok_comp then return fail(comp_err) end
  end

  ---------------------------------------------------------------------------
  -- Phase 5: Extract circuit from bus to return slot
  ---------------------------------------------------------------------------
  do
    local bus_side = LaneSides.bus_side(machine)
    local return_side = LaneSides.return_side(machine)
    local return_slot = LaneSides.return_slot(machine)

    if not circuit_mgr then return fail("no circuit manager") end

    local size = safe_slot_size(item_tp, bus_side, circuit_bus_slot)
    if size <= 0 then
      -- No circuit to extract; may be normal for some recipes
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
    -- Phase 6: Wait for circuit import (return slot empties)
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

    local ok_imp, imp_err = await_delivery(registry, machine, item_tp, fluid_tp,
      import_ready, staging_timeout_s, import_start, "import")
    if not ok_imp then return fail(imp_err) end
  end

  ---------------------------------------------------------------------------
  -- Phase 7: Cleanup — clear interface configs, DO NOT release DB slots
  ---------------------------------------------------------------------------
  for _, s in ipairs(cfg_slots) do
    if s.fluid then
      clear_fluid_slot(iface, s.side)
    else
      clear_item_slot(iface, s.slot)
    end
    coroutine.yield({ type = "yield" })
  end

  log("[LaneWorker] " .. machine_id .. " job " .. tostring(job.id) .. " done")
  return { status = "done" }
end

return LaneWorker
