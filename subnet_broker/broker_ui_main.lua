--[[
  AutoOS — Broker UI Main Entry Point

  Boot: check for GPU, fall back gracefully.
  Load broker modules and start the broker TUI.

  If called as lua broker_ui_main.lua: starts standalone UI.
  If required as module: returns a start() function.

  Drives its own event loop. Broker state is refreshed by
  a pump function that runs machine_poll + rob:tick() on each cycle.
  For full lane-worker execution, run broker_main.lua on the same or a
  separate computer.
]]

local BROKER_BUILD = "2026-06-20-broker-ui-v2"

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local BrokerUIMain = {}

---------------------------------------------------------------------------
-- GPU detection
---------------------------------------------------------------------------

local function detect_gpu()
  local ok_comp, component = pcall(require, "component")
  if not ok_comp or not component then
    return nil, nil
  end

  local ok_gpu, has_gpu = pcall(function()
    return component.isAvailable("gpu")
  end)
  if not ok_gpu or not has_gpu then
    return nil, nil
  end

  local gpu = component.gpu
  local screen_addr = nil

  local ok_screen, has_screen = pcall(function()
    return component.isAvailable("screen")
  end)
  if ok_screen and has_screen then
    local screens = component.list("screen")
    if screens then
      for addr in screens do
        screen_addr = addr
        break
      end
    end
  end

  return gpu, screen_addr
end

---------------------------------------------------------------------------
-- Broker pump function builder
---------------------------------------------------------------------------

--- Build a pump function that polls machines and ticks the dispatcher.
--- This runs before each overseer render cycle so the displayed data
--- is always fresh.
--- @param ctx table  Broker context from BrokerMain.build()
--- @return function
local function build_pump_fn(ctx)
  local poll = ctx.poll
  local rob = ctx.rob
  local registry = ctx.registry
  local state = ctx.state
  local sched = ctx.scheduler

  return function()
    -- Step scheduler to advance lane workers / machine_poll / dispatch
    if sched then
      for _ = 1, 5 do pcall(sched.step, sched) end
    end
    -- Poll all machines
    local ok_poll, results = pcall(poll.poll_all, poll)
    if ok_poll and results then
      for mid, r in pairs(results) do
        state.poll_results[mid] = r
        if registry._poll_results then
          registry._poll_results[mid] = r
        end
      end
    end

    -- Run one dispatcher tick
    local ok_tick, _ = pcall(rob.tick, rob, state.poll_results)
    if not ok_tick then end
  end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------

--- Build the broker, create the overseer, and enter the event loop.
--- @return boolean success
function BrokerUIMain.start()
  local gpu, screen_addr = detect_gpu()

  print("[Broker] starting " .. BROKER_BUILD)
  print(string.format("[Broker] GPU: %s", (gpu and "yes") or "no (headless)"))

  -- Build broker context (registry, config, rob, poll, state)
  local BrokerMain
  local ok_bm, bm_result = pcall(require, "broker_main")
  if ok_bm then
    BrokerMain = bm_result
  else
    print("[Broker] broker_main not available: " .. tostring(bm_result))
    print("[Broker] running in display-only mode (no live broker data)")
  end

  local rob, config
  local pump_fn = nil

  if BrokerMain then
    local ok_ctx, ctx_or_err = BrokerMain.build()
    if ok_ctx and ctx_or_err then
      local ctx = ctx_or_err
      rob = ctx.rob
      config = ctx.config

      -- Build broker pump function for live data updates
      pump_fn = build_pump_fn(ctx)

      -- Spawn lane workers, machine_poll, central_dispatch coroutines
      BrokerMain.attach_tasks(ctx)

      print(string.format("[Broker] broker online — %s",
        tostring(config.subnet_id)))
    else
      print("[Broker] broker build failed: " .. tostring(ctx_or_err))
      print("[Broker] running in display-only mode")
      config = require("config")
    end
  else
    local ok_cfg, cfg = pcall(require, "config")
    if ok_cfg then config = cfg end
  end

  -- Detect uptime source
  local now_fn = os.clock
  local ok_comp, computer = pcall(require, "computer")
  if ok_comp and computer and type(computer.uptime) == "function" then
    now_fn = function() return computer.uptime() end
  end

  -- Load broker UI page manager
  local BrokerUI = require("broker_ui")

  local deps = {
    gpu = gpu,
    screen_addr = screen_addr,
    now_fn = now_fn,
    log = print,
    pump_fn = pump_fn,
  }

  local ui = BrokerUI.new(rob, config, deps)
  ui:run()

  return true
end

---------------------------------------------------------------------------
-- Auto-start detection
---------------------------------------------------------------------------

local function should_autostart()
  local info = debug.getinfo(2, "S")
  if info and info.what == "C" then
    return false
  end
  return true
end

if should_autostart() then
  local ok, err = pcall(BrokerUIMain.start)
  if not ok then
    print("[Broker] FATAL:\n" .. tostring(err))
  end
end

return BrokerUIMain
