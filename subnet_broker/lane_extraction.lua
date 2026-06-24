--[[
  AutoOS — Lane Extraction (Phases 6-7)
  Extract circuit from bus → wait for circuit import.
  Extracted from lane_worker.lua.
]]

local LaneContext = require("lane_context")
local LaneSides = require("lane_sides")

local Extraction = {}

--- Extract circuit from bus to return slot, then wait for AE2 import.
---@param ctx table  lane context
---@return boolean ok
---@return string|nil err
function Extraction.run(ctx)
  local bus_side = LaneSides.bus_side(ctx.machine)
  local return_side = LaneSides.return_side(ctx.machine)
  local return_slot = LaneSides.return_slot(ctx.machine)

  if not ctx.circuit_mgr then return ctx:fail("no circuit manager") end

  ---------------------------------------------------------------------------
  -- Phase 6: Extract circuit from bus to return slot
  ---------------------------------------------------------------------------
  local size = LaneContext.safe_slot_size(ctx.item_tp, bus_side, ctx.circuit_bus_slot)
  if size <= 0 then
    ctx:log("[LaneWorker] " .. ctx.machine_id .. " Phase6: no circuit on bus (slot "
      .. ctx.circuit_bus_slot .. "), skipping extract")
  else
    ctx:log(string.format("[LaneWorker] %s Phase6: extracting circuit bus[%d]:%d -> return[%d]:%s",
      ctx.machine_id, bus_side, ctx.circuit_bus_slot, return_side,
      tostring(return_slot or "auto")))
    local moved, err = ctx.circuit_mgr:transfer_one(ctx.item_tp, bus_side, return_side,
      ctx.circuit_bus_slot, return_slot)
    if not moved or moved < 1 then
      return ctx:fail("circuit extract: " .. tostring(err or "transfer failed"))
    end
    ctx:log(string.format("[LaneWorker] %s Phase6: circuit extracted (%d moved)",
      ctx.machine_id, moved))
    coroutine.yield({ type = "sleep", seconds = 0 })
  end

  ---------------------------------------------------------------------------
  -- Phase 7: Wait for circuit import (return slot empties)
  ---------------------------------------------------------------------------
  ctx:log(string.format("[LaneWorker] %s Phase7: waiting for circuit import (return[%d]:%s)",
    ctx.machine_id, return_side, tostring(return_slot or "auto")))
  local import_start = ctx.now_fn()
  local function import_ready()
    if return_slot then
      return LaneContext.safe_slot_size(ctx.item_tp, return_side, return_slot) == 0
    end
    local max_slot = LaneContext.pull_scan_max(ctx.item_tp, return_side)
    for slot = 1, max_slot do
      if slot % 10 == 0 then coroutine.yield({ type = "sleep", seconds = 0 }) end
      if LaneContext.safe_slot_size(ctx.item_tp, return_side, slot) > 0 then return false end
    end
    return true
  end

  local ok_imp, imp_err = LaneContext.await_delivery(ctx,
    import_ready, ctx.staging_timeout_s, import_start, "import")
  if not ok_imp then return ctx:fail(imp_err) end
  ctx:log(string.format("[LaneWorker] %s Phase7: circuit imported (%.1fs)",
    ctx.machine_id, ctx.now_fn() - import_start))

  return true
end

return Extraction
