--[[
  AutoOS — Lane Stocking (Phases 1-4)
  Stock ME interface → wait AE2 delivery → transfer items → cleanup+pulse.
  Extracted from lane_worker.lua.
]]

local LaneContext = require("lane_context")
local LaneSides = require("lane_sides")
local FluidTanks = require("fluid_tanks")

local Stocking = {}

function Stocking.run(ctx)
  local q = ctx.queue

  ctx:log(string.format("[LaneWorker] %s START job=%s  items=%d fluids=%d steps=%d",
    ctx.machine_id, tostring(ctx.job.id),
    type(ctx.job.manifest.items) == "table" and #ctx.job.manifest.items or 0,
    type(ctx.job.manifest.fluids) == "table" and #ctx.job.manifest.fluids or 0,
    #q))

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

    ctx:log(string.format("[LaneWorker] %s Phase1: stocking %d step(s)", ctx.machine_id, #q))
    for i, step in ipairs(q) do
      ctx:log(string.format("[LaneWorker] %s Phase1: ENTER step %d/%d kind=%s",
        ctx.machine_id, i, #q, step.kind))
      if step.kind == "fluid" then
        local side = next_fluid_side()
        if not side then return ctx:fail("no free interface sides for fluid: " .. tostring(step.fluid_label or "?")) end
        if not ctx.iface then return ctx:fail("no ME interface for fluid stock") end
        ctx:log(string.format("[LaneWorker] %s Phase1: fluid[%d/%d] TRY %q -> side %d  DB[%s:%d] filter=%s registry=%s amount=%s",
          ctx.machine_id, i, #q, tostring(step.fluid_label or "?"),
          side, tostring(step.db_address), step.db_slot or -1,
          tostring(step.fluid_filter and step.fluid_filter.label or "nil"),
          tostring(step.fluid_registry or "nil"),
          tostring(step.fluid_amount_mb)))
        local ok, err = LaneContext.stock_fluid_slot(ctx.iface, side, step.db_address, step.db_slot)
        if not ok then return ctx:fail("fluid stock side " .. side .. ": " .. tostring(err)) end
        ctx.cfg_slots[#ctx.cfg_slots + 1] = { fluid = true, side = side }
        ctx:log(string.format("[LaneWorker] %s Phase1: fluid[%d/%d] %q -> side %d  DB[%s:%d]",
          ctx.machine_id, i, #q, tostring(step.fluid_label or "?"),
          side, tostring(step.db_address), step.db_slot or -1))
      else
        item_idx = item_idx + 1
        local iface_slot = ctx.slot_start + item_idx - 1
        if not ctx.iface then return ctx:fail("no ME interface for item stock") end
        local ok, err = LaneContext.stock_item_slot(ctx.iface, iface_slot, step.db_address,
          step.db_slot, step.count or 1)
        if not ok then return ctx:fail("item stock slot " .. iface_slot .. ": " .. tostring(err)) end
        ctx.cfg_slots[#ctx.cfg_slots + 1] = { slot = iface_slot }
        ctx:log(string.format("[LaneWorker] %s Phase1: item[%d/%d] %q x%d -> slot %d  DB[%s:%d]",
          ctx.machine_id, i, #q, tostring(step.name or "?"),
          step.count or 1, iface_slot,
          tostring(step.db_address), step.db_slot or -1))
      end
    end

    ctx:log(string.format("[LaneWorker] %s Phase1: all %d steps stocked, cfg_slots=%d",
      ctx.machine_id, #q, #ctx.cfg_slots))
    coroutine.yield({ type = "sleep", seconds = 0 })

    -- Fill remaining free sides with duplicate fluid configs.
    local fluid_steps = {}
    for _, step in ipairs(q) do
      if step.kind == "fluid" then
        local amount = step.fluid_amount_mb
        if amount == nil or amount > 16000 then
          fluid_steps[#fluid_steps + 1] = step
        end
      end
    end
    if #fluid_steps > 0 then
      ctx:log(string.format("[LaneWorker] %s Phase1: filling %d remaining side(s) with duplicates of %d large fluid(s)",
        ctx.machine_id, 6 - #q, #fluid_steps))
      local dup_idx = 0
      local side = next_fluid_side()
      while side do
        dup_idx = dup_idx + 1
        local step = fluid_steps[(dup_idx - 1) % #fluid_steps + 1]
        local ok, err = LaneContext.stock_fluid_slot(ctx.iface, side, step.db_address, step.db_slot)
        if not ok then
          ctx:log("[LaneWorker] " .. ctx.machine_id .. " duplicate fluid stock side " .. side .. " failed: " .. tostring(err))
        else
          ctx.cfg_slots[#ctx.cfg_slots + 1] = { fluid = true, side = side }
          ctx:log(string.format("[LaneWorker] %s Phase1: dup fluid %q -> side %d",
            ctx.machine_id, tostring(step.fluid_label or "?"), side))
        end
        coroutine.yield({ type = "sleep", seconds = 0 })
        side = next_fluid_side()
      end
    end
  end

  ctx:log("[LaneWorker] " .. ctx.machine_id .. " stocked " .. #ctx.cfg_slots .. " interface slot(s)")

  ---------------------------------------------------------------------------
  -- Phase 2: Wait for AE2 delivery
  ---------------------------------------------------------------------------
  if not ctx.item_tp then
    return ctx:fail("item transposer proxy unavailable")
  end

  do
    ctx:log(string.format("[LaneWorker] %s Phase2: waiting for AE2 delivery (%.0fs timeout)",
      ctx.machine_id, ctx.interface_wait_s))
    local delivery_start = ctx.now_fn()
    local function delivery_ready()
      for _, step in ipairs(q) do
        if step.kind == "item" and not LaneContext.step_visible(ctx.item_tp, ctx.machine, step) then
          return false
        end
      end
      return true
    end

    local ok_del, del_err = LaneContext.await_delivery(ctx,
      delivery_ready, ctx.interface_wait_s, delivery_start, "delivery")
    if not ok_del then return ctx:fail(del_err) end
    ctx:log(string.format("[LaneWorker] %s Phase2: all %d item(s) visible on pull face (%.1fs)",
      ctx.machine_id, #q, ctx.now_fn() - delivery_start))
  end

  ---------------------------------------------------------------------------
  -- Phase 3: Transfer items through transposer to machine input bus
  ---------------------------------------------------------------------------
  do
    local total_moved = 0
    for i, step in ipairs(q) do
      if step.kind ~= "item" then goto continue_item end
      local item_deadline = ctx.now_fn() + ctx.staging_timeout_s
      local moved_total = 0
      -- Circuit items must target the protected circuit slot so GT doesn't consume them
      local is_circuit = step.name == ctx.circuit_item_name
        or (type(step.name) == "string" and step.name:find("integrated_circuit", 1, true) ~= nil)
      local target_slot = is_circuit and ctx.circuit_bus_slot or nil
      ctx:log(string.format("[LaneWorker] %s Phase3: xfer item[%d/%d] %q x%d  (bus side %d, %s)",
        ctx.machine_id, i, #q, tostring(step.name or "?"),
        step.count or 1, LaneSides.bus_side(ctx.machine),
        is_circuit and ("target=slot" .. tostring(ctx.circuit_bus_slot)) or "target=any"))
      while moved_total < (step.count or 1) do
        local moved = LaneContext.transfer_item_step(ctx.item_tp, ctx.machine, step, target_slot)
        if moved and moved >= 1 then
          moved_total = moved_total + moved
          total_moved = total_moved + moved
        else
          if not LaneContext.step_visible(ctx.item_tp, ctx.machine, step) then break end
          coroutine.yield({ type = "sleep", seconds = 0 })
        end
        if ctx.now_fn() >= item_deadline then
          return ctx:fail("item transfer timeout for " .. tostring(step.name or "?"))
        end
      end
      ctx:log(string.format("[LaneWorker] %s Phase3: item[%d/%d] moved %d/%d",
        ctx.machine_id, i, #q, moved_total, step.count or 1))
      ::continue_item::
    end
    ctx:log(string.format("[LaneWorker] %s Phase3: transfer done — %d item(s) total moved=%d",
      ctx.machine_id, #q, total_moved))
  end

  ctx:log("[LaneWorker] " .. ctx.machine_id .. " transfer complete")

  ---------------------------------------------------------------------------
  -- Phase 4: Wait for dual IF pull face to empty, then cleanup + pulse
  ---------------------------------------------------------------------------
  do
    local drain_start = ctx.now_fn()
    local function pull_face_empty()
      return not LaneContext.pull_face_has_items(ctx.item_tp, ctx.machine)
    end

    ctx:log(string.format("[LaneWorker] %s Phase4a: waiting for pull face empty (%.0fs timeout)",
      ctx.machine_id, ctx.staging_timeout_s))
    local ok_drain, drain_err = LaneContext.await_delivery(ctx,
      pull_face_empty, ctx.staging_timeout_s, drain_start, "dual_if_drain")
    if not ok_drain then return ctx:fail(drain_err) end
    ctx:log(string.format("[LaneWorker] %s Phase4a: pull face empty (%.1fs)",
      ctx.machine_id, ctx.now_fn() - drain_start))

    -- Clear item configs first
    local has_fluid_cfgs = false
    local items_cleared = 0
    for _, s in ipairs(ctx.cfg_slots) do
      if s.fluid then
        has_fluid_cfgs = true
      else
        LaneContext.clear_item_slot(ctx.iface, s.slot)
        items_cleared = items_cleared + 1
      end
    end
    ctx:log(string.format("[LaneWorker] %s Phase4a: cleared %d item config(s), has_fluid=%s",
      ctx.machine_id, items_cleared, tostring(has_fluid_cfgs)))

    -- Wait for fluid buffer to drain
    if has_fluid_cfgs then
      local fluid_buffer_side = LaneSides.central_fluid_pull_side(ctx.machine)
      ctx:log(string.format("[LaneWorker] %s Phase4b: waiting for fluid buffer side %d to drain",
        ctx.machine_id, fluid_buffer_side))
      local fluid_drain_start = ctx.now_fn()
      local prev_level = FluidTanks.tank_level(ctx.item_tp, fluid_buffer_side)
      ctx:log(string.format("[LaneWorker] %s Phase4b: initial fluid level=%d", ctx.machine_id, prev_level))
      local function fluid_buffer_empty()
        return FluidTanks.buffer_empty(ctx.item_tp, fluid_buffer_side)
      end
      local ok_fluid, fluid_err = LaneContext.await_delivery(ctx,
        fluid_buffer_empty, ctx.staging_timeout_s, fluid_drain_start, "fluid_drain")
      if not ok_fluid then return ctx:fail(fluid_err) end
      ctx:log(string.format("[LaneWorker] %s Phase4b: fluid buffer drained (%.1fs)",
        ctx.machine_id, ctx.now_fn() - fluid_drain_start))

      local fluids_cleared = 0
      for _, s in ipairs(ctx.cfg_slots) do
        if s.fluid then
          LaneContext.clear_fluid_slot(ctx.iface, s.side)
          fluids_cleared = fluids_cleared + 1
        end
      end
      ctx:log(string.format("[LaneWorker] %s Phase4b: cleared %d fluid config(s)", ctx.machine_id, fluids_cleared))
    end

    -- Pulse redstone to ungate central buffer
    local redstone_addr = ctx.config.redstone_address
    if redstone_addr and redstone_addr ~= "" then
      ctx:log(string.format("[LaneWorker] %s Phase4c: pulse redstone %s side %d",
        ctx.machine_id, redstone_addr, ctx.config.redstone_side or 0))
      local rs = ctx.registry.get_redstone(redstone_addr)
      if rs and rs.setOutput then
        local rs_side = ctx.config.redstone_side or 0
        local pulse_s = ctx.config.redstone_pulse_s or 0.1
        pcall(rs.setOutput, rs_side, 15)
        coroutine.yield({ type = "sleep", seconds = pulse_s })
        -- RAW TRACE 1: proves coroutine resumed from yield (no pcall wrapper)
        local tf = io.open("/home/subnet_broker/lane_worker.log", "a")
        if tf then tf:write("[TRACE] RESUMED after redstone yield\n") tf:close() end
        pcall(rs.setOutput, rs_side, 0)
      end
    end
    ctx:log("[LaneWorker] " .. ctx.machine_id .. " Phase4: cleanup+pulse done")
  end

  -- Release transport locks so other lanes can use the transposer
  if ctx.registry.release_transport_locks then
    ctx.registry.release_transport_locks(ctx.machine_id)
  end

  -- RAW TRACE 2: proves function is about to return
  local tf2 = io.open("/home/subnet_broker/lane_worker.log", "a")
  if tf2 then tf2:write("[TRACE] LaneStocking.run about to return true\n") tf2:close() end

  return true
end

return Stocking
