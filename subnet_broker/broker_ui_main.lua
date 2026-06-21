--[[
  AutoOS — Broker Monitor Dashboard (simplified)
  Display-only status screen.  No config editor, no log viewer.
  S to start/stop broker, Q to quit.
  This script lives in /home/.  Dependencies are in /home/subnet_broker/.
  Run: lua broker_ui_main.lua
]]

local BROKER_BUILD = "2026-06-21-dashboard-standalone"

-- This script lives in /home/.  Dependencies are in /home/subnet_broker/.
local sep = package.config:sub(1, 1)
package.path = "/home/subnet_broker" .. sep .. "?.lua;" .. package.path

---------------------------------------------------------------------------
-- GPU detection
---------------------------------------------------------------------------
local function detect_gpu()
  local ok_comp, component = pcall(require, "component")
  if not ok_comp or not component then return nil, nil end
  local ok_gpu = pcall(function() return component.isAvailable("gpu") end)
  if not ok_gpu then return nil, nil end
  local gpu = component.gpu
  local screen_addr = nil
  if pcall(function() return component.isAvailable("screen") end) then
    for addr in component.list("screen") do screen_addr = addr; break end
  end
  return gpu, screen_addr
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
local gpu, screen_addr = detect_gpu()
if not gpu then
  print("[Broker] no GPU — headless mode, exiting")
  return
end

local function file_log(msg)
  local f = io.open("/home/subnet_broker/lane_worker.log", "a")
  if f then f:write(tostring(msg) .. "\n"); f:close() end
end

local theme = {
  bg_default     = 0x000000,  bg_panel       = 0x1A1A1A,
  text_primary   = 0xFFFFFF,  text_muted     = 0x888888,
  accent_success = 0x00FF00,  accent_error   = 0xFF0000,
  accent_warning = 0xFFA500,  highlight      = 0x0055FF,
  dim_text       = 0x404040,
}

local now_fn = os.clock
pcall(function() now_fn = require("computer").uptime end)

-- Build broker context
local BrokerMain = require("broker_main")
local ctx = BrokerMain.build(file_log)
local rob, config, broker_active, status = nil, nil, false, "Press S to start broker"
local pump_co = nil

if ctx then
  rob, config = ctx.rob, ctx.config
  print(string.format("[Broker] ready — %s (press S to start)", tostring(config.subnet_id)))
else
  print("[Broker] build failed — display-only mode")
  config = require("config")
end

---------------------------------------------------------------------------
-- Incremental machine poll (round-robin, 2 per call)
---------------------------------------------------------------------------
local poll_mids, poll_index = {}, 1
for _, m in ipairs(config.machines or {}) do poll_mids[#poll_mids + 1] = m end

local function incremental_poll()
  if #poll_mids == 0 then return end
  for _ = 1, 2 do
    local m = poll_mids[poll_index]
    if m then
      local ok, result = pcall(ctx.poll.poll_machine, ctx.poll, m)
      if ok and result then ctx.state.poll_results[m.id] = result end
    end
    poll_index = poll_index + 1
    if poll_index > #poll_mids then poll_index = 1 end
  end
end

---------------------------------------------------------------------------
-- Dashboard data builder
---------------------------------------------------------------------------
local dispatch_log, prev_lane_states = {}, {}
local start_time = now_fn()

local function build_dashboard_data()
  -- Track lane state transitions
  if rob then
    local dbg = rob:get_debug()
    for mid, lane in pairs(dbg.lanes or {}) do
      local prev = prev_lane_states[mid]
      if prev and prev ~= lane.state then
        dispatch_log[#dispatch_log + 1] = {
          job_id = lane.current_job_id, machine_id = mid, time = now_fn(),
          status = (lane.state == "WORKING" and "running")
                or (lane.state == "IDLE" and (prev == "WORKING" and "done" or "idle"))
                or (lane.state == "FAULTED" and "failed") or lane.state,
        }
        while #dispatch_log > 50 do table.remove(dispatch_log, 1) end
      end
      prev_lane_states[mid] = lane.state
    end
  end
  -- Merge config machines into lanes (show all, IDLE if never dispatched)
  local lanes = {}
  for _, m in ipairs(config.machines or {}) do
    lanes[m.id] = { state = "IDLE", current_job_id = nil, last_error = nil, state_entered_at = nil }
  end
  if rob then
    for mid, lane in pairs(rob:get_debug().lanes or {}) do lanes[mid] = lane end
  end
  return {
    lanes = lanes, pending = rob and rob:pending_queue() or {},
    locks = rob and rob:get_locks() or {}, dispatch_log = dispatch_log,
    subnet_id = config.subnet_id or "?", uptime = now_fn() - start_time,
    port = config.broker_modem_port or config.main_net_channel or 0,
    max_lanes = #(config.machines or {}), now_fn = now_fn,
    broker_active = broker_active, status = status,
  }
end

---------------------------------------------------------------------------
-- Pump coroutine (3-phase: scheduler → poll → dispatch)
---------------------------------------------------------------------------
local function build_pump_coroutine()
  local sched, poll, rob_, st = ctx.scheduler, ctx.poll, ctx.rob, ctx.state
  return coroutine.create(function()
    local phase = 1
    while broker_active do
      if phase == 1 then
        if sched then
          for _ = 1, 3 do pcall(sched._resume_due, sched) end
        end
        phase = 2; coroutine.yield()
      elseif phase == 2 then
        incremental_poll()
        phase = 3; coroutine.yield()
      elseif phase == 3 then
        pcall(rob_.tick, rob_, st.poll_results, function() os.sleep(0) end)
        page._is_dirty = true
        phase = 1; coroutine.yield()
      end
    end
  end)
end

local function drain_pump()
  if not pump_co then return end
  if coroutine.status(pump_co) ~= "suspended" then pump_co = nil; return end
  for _ = 1, 4 do
    if coroutine.status(pump_co) ~= "suspended" then break end
    local success, err = xpcall(
      function() coroutine.resume(pump_co) end, debug.traceback)
    if not success then
      file_log("[UI] pump crashed:\n" .. tostring(err))
      status = "Pump crashed"; broker_active = false; pump_co = nil; return
    end
  end
end

---------------------------------------------------------------------------
-- Dashboard page
---------------------------------------------------------------------------
local U = require("ui_utils")
local DashboardPage = require("page_dashboard")
local page = DashboardPage.new({ gpu = gpu, screen_addr = screen_addr, theme = theme, now_fn = now_fn })

---------------------------------------------------------------------------
-- Event loop
---------------------------------------------------------------------------
local event = require("event")
if screen_addr then pcall(gpu.bind, screen_addr) end
local mw, mh = 80, 25
pcall(function()
  local ok, w, h = pcall(gpu.getResolution)
  if ok and w and h then mw, mh = w, h end
end)
pcall(gpu.setResolution, mw, mh)

page._w, page._h = mw, mh - 1
page:set_data(build_dashboard_data())
page._is_dirty = true

local running, last_pump, last_render = true, 0, 0
while running do
  local ev = { event.pull(0.05) }
  if ev[1] == "key_down" then
    local code = ev[4]
    if code == 16 then  -- Q quits
      if broker_active then
        if ctx and ctx.scheduler then pcall(ctx.scheduler.clear, ctx.scheduler) end
        if ctx and ctx.poll then ctx.poll.proxies, ctx.poll.proxy_errors = {}, {}; ctx.poll.proxy_cache_stale = true end
        pump_co = nil; broker_active = false
      end
      running = false
    elseif code == 31 then  -- S = start/stop broker
      if broker_active then
        if ctx and ctx.scheduler then pcall(ctx.scheduler.clear, ctx.scheduler) end
        if ctx and ctx.poll then ctx.poll.proxies, ctx.poll.proxy_errors = {}, {}; ctx.poll.proxy_cache_stale = true end
        pump_co = nil; broker_active = false; status = "Broker STOPPED"
      elseif ctx then
        pcall(function()
          if BrokerMain and BrokerMain.attach_tasks then BrokerMain.attach_tasks(ctx) end
        end)
        pump_co = build_pump_coroutine()
        broker_active = true; status = "Broker RUNNING"
      else
        status = "No broker context — cannot start"
      end
    end
  end
  local now = now_fn()
  -- Backend pump at 20Hz (50ms gate)
  if broker_active and now - last_pump > 0.05 then
    drain_pump()
    page:set_data(build_dashboard_data())
    last_pump = now
  end
  -- Render at 2fps or on dirty flag
  if page._is_dirty or (now - last_render >= 0.5) then
    pcall(page.render, page)
    page._is_dirty = false
    last_render = now
  end
end

pcall(gpu.fill, 1, 1, mw, mh, " ")
pcall(gpu.setForeground, 0xFFFFFF)
pcall(gpu.set, 1, 1, "AutoOS Broker stopped.")
