--[[
  AutoOS — Lane Worker (Event-Driven Coroutine)

  Each lane is its own coroutine.  This function is the coroutine body.
  It consumes a pre-built Job Object from the Dispatcher and executes
  it end-to-end.

  Phase: stock → wait_delivery → transfer → wait_dual_if_empty → cleanup+pulse
          → wait_complete → extract → wait_import

  Refactored into composition modules:
    lane_context    — shared helpers + context builder
    lane_stocking   — Phases 1-4
    lane_completion — Phase 5
    lane_extraction — Phases 6-7

  Constraints:
    - NEVER call component.proxy() — all proxies come from registry
    - All component calls wrapped in pcall()
    - Yield at least once per "step"
]]

local LaneContext = require("lane_context")
local LaneStocking = require("lane_stocking")
local LaneCompletion = require("lane_completion")
local LaneExtraction = require("lane_extraction")
local FaultNet = require("fault_net")

local LaneWorker = {}

--- Execute a pre-built Job Object on one lane.
---@param registry table
---@param job table  Pre-built Job Object with manifest.{items,fluids,queue}
---@param machine_id string
---@return table { status = "done"|"failed", error = string|nil }
function LaneWorker.execute(registry, job, machine_id, event)
  local ctx = LaneContext.build(registry, job, machine_id)
  if not ctx then
    return { status = "failed", error = "machine not found: " .. tostring(machine_id) }
  end

  -- Phases 1-4: Stock, deliver, transfer, cleanup
  local ok, err = FaultNet.guard(ctx, "lane.stocking." .. machine_id, LaneStocking.run, ctx)
  if not ok then return { status = "failed", error = err } end

  -- RAW TRACE: proves we reached Phase 5 code
  local tf3 = io.open("/home/subnet_broker/lane_worker.log", "a")
  if tf3 then tf3:write("[TRACE] entering Phase 5 now\n") tf3:close() end

  -- Phase 5: Wait for machine completion
  ok, err = FaultNet.guard(ctx, "lane.completion." .. machine_id, LaneCompletion.run, ctx)
  if not ok then return { status = "failed", error = err } end

  -- Phases 6-7: Extract circuit, wait import
  ok, err = FaultNet.guard(ctx, "lane.extraction." .. machine_id, LaneExtraction.run, ctx)
  if not ok then return { status = "failed", error = err } end

  ctx:log("[LaneWorker] " .. machine_id .. " job " .. tostring(job.id) .. " DONE")
  ctx:flush_log()
  return { status = "done" }
end

return LaneWorker
