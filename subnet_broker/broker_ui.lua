-- broker_ui.lua - AutoOS Broker TUI (router + event loop)
-- Lua 5.2, OpenComputers.
-- Pages live in page_*.lua, utilities in ui_utils.lua, components in ui_components.lua.
-- ponytail: incremental polling + render throttle + color batching; add full poll_all fallback if machines < 3.

local BrokerUI = {}; BrokerUI.__index = BrokerUI
local U = require("ui_utils")

local LOG_PATH = "/home/subnet_broker/lane_worker.log"

-----------------------------------------------------------------------
-- Constructor
-----------------------------------------------------------------------
function BrokerUI.new(rob, config, deps)
  deps = deps or {}
  local self = setmetatable({}, BrokerUI)
  self._rob = rob; self._config = config or {}
  self._gpu = deps.gpu; self._screen_addr = deps.screen_addr
  self._now = deps.now_fn or os.clock; self._log = deps.log or print
  self._pump_fn = deps.pump_fn
  self._current_page = nil  -- set by add_page (first registered wins)
  self._dispatch_log = {}; self._prev_lane_states = {}
  self._running = false; self._start_time = self._now()
  self._broker_ctx = deps.broker_ctx; self._broker_bm = deps.broker_bm
  self._broker_active = false; self._status = "Press S to start broker"
  self._last_render = 0
  self._page_dirty = false
  -- Incremental polling state
  self._poll_mids = nil; self._poll_index = 1
  -- Page instances (registered via add_page)
  self._page_instances = {}
  return self
end

-----------------------------------------------------------------------
-- Page registration
-----------------------------------------------------------------------
function BrokerUI:add_page(page_instance)
  local id = page_instance and page_instance.page_id
  if not id then
    if self._log then self._log("[BrokerUI] page missing page_id, skipping") end
    return
  end
  self._page_instances[id] = page_instance
  -- First page registered becomes the default
  if not self._current_page then
    self._current_page = id
  end
end

-----------------------------------------------------------------------
-- Incremental round-robin polling (replaces poll_all)
-----------------------------------------------------------------------
function BrokerUI:_incremental_poll(poll_obj, st, batch_size)
  batch_size = batch_size or 2
  local mids = self._poll_mids
  if not mids or #mids == 0 then
    mids = {}
    for _, m in ipairs(self._config.machines or {}) do
      mids[#mids + 1] = m
    end
    self._poll_mids = mids
    self._poll_index = 1
  end
  if #mids == 0 then return end
  local idx = self._poll_index
  for _ = 1, batch_size do
    local m = mids[idx]
    if m then
      local ok, result = pcall(poll_obj.poll_machine, poll_obj, m)
      if ok and result then
        st.poll_results[m.id] = result
      end
    end
    idx = idx + 1
    if idx > #mids then idx = 1 end
  end
  self._poll_index = idx
end

-----------------------------------------------------------------------
-- Broker start/stop
-----------------------------------------------------------------------
function BrokerUI:_start_broker()
  if self._broker_active then self._status = "Broker already running"; return end
  local ctx = self._broker_ctx
  if not ctx then
    -- Try to build broker context on-demand
    self._status = "Building broker..."
    local ok, bm = pcall(require, "broker_main")
    if ok and bm then
      local okb, result = pcall(bm.build, bm)
      if okb and result then
        ctx = result; self._broker_ctx = ctx; self._broker_bm = bm
        self._rob = ctx.rob; self._config = ctx.config
        -- Basic pump with incremental polling
        local poll, rob, st = ctx.poll, ctx.rob, ctx.state
        self._pump_fn = function()
          self:_incremental_poll(poll, st)
          pcall(rob.tick, rob, st.poll_results)
        end
        self._status = "Broker built -- starting..."
      else
        local msg = "Build failed: "
        if type(result) == "string" then msg = msg .. result
        elseif type(okb) == "string" then msg = msg .. okb
        else msg = msg .. tostring(result or okb) end
        self._status = msg; return
      end
    else self._status = "broker_main not available"; return end
  end
  local ok, err = pcall(function()
    if self._broker_bm and self._broker_bm.attach_tasks then self._broker_bm.attach_tasks(ctx) end
    if ctx.scheduler and ctx.poll and ctx.rob then
      local sched, poll, rob, st = ctx.scheduler, ctx.poll, ctx.rob, ctx.state
      self._pump_fn = function()
        pcall(function()
          if sched then
            -- Drain ready coroutines (mimics Scheduler:run inner loop)
            for _ = 1, 20 do pcall(sched._resume_due, sched) end
          end
          self:_incremental_poll(poll, st)
          pcall(rob.tick, rob, st.poll_results)
        end)
      end
    end
  end)
  if not ok then self._status = "Start FAILED: "..tostring(err); return end
  self._broker_active = true; self._status = "Broker RUNNING"
end

function BrokerUI:_stop_broker()
  if not self._broker_active then return end
  local ctx = self._broker_ctx
  if ctx and ctx.scheduler then pcall(ctx.scheduler.clear, ctx.scheduler) end
  self._broker_active = false
  if ctx then
    local poll, rob, st = ctx.poll, ctx.rob, ctx.state
    self._pump_fn = function()
      self:_incremental_poll(poll, st)
      pcall(rob.tick, rob, st.poll_results)
    end
  end
  self._status = "Broker STOPPED"
end

-----------------------------------------------------------------------
-- Dispatch ring buffer
-----------------------------------------------------------------------
function BrokerUI:_track_dispatch()
  if not self._rob then return end
  local dbg = self._rob:get_debug(); local lanes = dbg.lanes or {}
  for mid, lane in pairs(lanes) do
    local prev = self._prev_lane_states[mid]; local curr = lane.state
    if prev and prev ~= curr then
      local e = { job_id = lane.current_job_id, machine_id = mid, time = self._now() }
      if curr == "WORKING" then e.status = "running"
      elseif curr == "IDLE" then e.status = prev == "WORKING" and "done" or "idle"
      elseif curr == "FAULTED" then e.status = "failed" else e.status = curr end
      self._dispatch_log[#self._dispatch_log + 1] = e
      while #self._dispatch_log > 50 do table.remove(self._dispatch_log, 1) end
    end
    self._prev_lane_states[mid] = curr
  end
end

function BrokerUI:_build_dashboard_data()
  local max_lanes = #(self._config.machines or {})
  local base = {
    subnet_id=self._config.subnet_id or "?", uptime=self._now()-self._start_time,
    port=self._config.broker_modem_port or self._config.main_net_channel or 0,
    max_lanes=max_lanes, now_fn=self._now, broker_active=self._broker_active, status=self._status }
  -- Merge config machines into lanes: show all machines, IDLE if never dispatched
  local lanes = {}
  for _, m in ipairs(self._config.machines or {}) do
    lanes[m.id] = { state = "IDLE", current_job_id = nil, last_error = nil, state_entered_at = nil }
  end
  if self._rob then
    local dbg = self._rob:get_debug()
    for mid, lane in pairs(dbg.lanes or {}) do
      lanes[mid] = lane
    end
    return { lanes=lanes, pending=self._rob:pending_queue(),
      locks=self._rob:get_locks(), dispatch_log=self._dispatch_log, debug=dbg,
      subnet_id=base.subnet_id, uptime=base.uptime, port=base.port,
      max_lanes=base.max_lanes, now_fn=base.now_fn, broker_active=base.broker_active, status=base.status }
  end
  return { lanes=lanes, pending={}, locks={}, dispatch_log=self._dispatch_log, debug={},
    subnet_id=base.subnet_id, uptime=base.uptime, port=base.port,
    max_lanes=base.max_lanes, now_fn=base.now_fn, broker_active=base.broker_active, status=base.status }
end

-----------------------------------------------------------------------
-- Data refresh
-----------------------------------------------------------------------
function BrokerUI:_refresh_data()
  self:_track_dispatch()
  local page = self._page_instances[self._current_page]
  if not page then return end
  if self._current_page == "dashboard" then
    page:set_data(self:_build_dashboard_data())
  elseif self._current_page == "logs" then
    local lines = {}
    local f = io.open(LOG_PATH, "r")
    if f then for line in f:lines() do lines[#lines+1] = line end; f:close() end
    page:set_data({ lines = lines, path = LOG_PATH, follow = true, offset = 0 })
  elseif self._current_page == "config" then
    page:set_data({ _locked = self._broker_active })
  end
end

-----------------------------------------------------------------------
-- Navigation
-----------------------------------------------------------------------
function BrokerUI:_nav_to(name)
  local page = self._page_instances[name]
  if not page or self._current_page == name then return end
  -- Unmount old page
  local old_page = self._page_instances[self._current_page]
  if old_page and old_page.on_unmount then
    pcall(old_page.on_unmount, old_page)
  end
  self._current_page = name
  -- Mount new page
  if page.on_mount then
    pcall(page.on_mount, page)
  end
  self:_refresh_data()
  self._page_dirty = true
  pcall(self._render, self)
end

function BrokerUI:_nav_next()
  local order = {"dashboard","logs","config"}
  for i, n in ipairs(order) do
    if n == self._current_page then
      self:_nav_to(order[i % 3 + 1])
      return
    end
  end
end

-----------------------------------------------------------------------
-- Key handling (event = {code=scancode, char=ASCII})
-----------------------------------------------------------------------
function BrokerUI:_handle_key(code, char)
  local page = self._page_instances[self._current_page]
  if not page then return end

  -- Refresh config lock state before routing
  if self._current_page == "config" then
    page._locked = self._broker_active
  end

  -- Global: Q quits (always, even when modal)
  if code == 16 then
    self:_stop_broker(); self._running = false; return
  end

  -- Global: Ctrl+S saves config (only config page handles it)
  if code == 31 and self._kb and self._kb.isControlDown() then
    if self._current_page == "config" and page.handle_input then
      page:handle_input({code=code, char=char})
      -- Full render needed — status bar may have changed
      self._last_render = 0
    end
    return
  end

  -- If config page is editing (modal), route ALL keys to it for text entry + Enter
  if self._current_page == "config" and page:is_modal() then
    -- Config page gets every key; it handles char entry, BS, Enter commit
    page:handle_input({code=code, char=char})
    self:_redraw_config_field_wrapper(code, char)
    return
  end

  -- Global navigation (only when NOT modal)
  if code == 2 then self:_nav_to("dashboard"); return      -- 1 key
  elseif code == 3 then self:_nav_to("logs"); return        -- 2 key
  elseif code == 4 then self:_nav_to("config"); return      -- 3 key
  elseif code == 31 then                                    -- S key (start/stop)
    if self._broker_active then self:_stop_broker() else self:_start_broker() end; return
  elseif code == 15 then self:_nav_next(); return            -- Tab
  elseif code == 14 and self._current_page == "config" then -- Backspace on config = go back
    self:_nav_to("dashboard"); return
  end

  -- Delegate to active page
  if page.handle_input then
    -- Snapshot config focus before handling (for targeted redraw detection)
    local old_fs, old_ff
    if self._current_page == "config" then
      old_fs = page._fs; old_ff = page._ff
    end

    page:handle_input({code=code, char=char})

    -- Config page: targeted redraw for field/section changes
    if self._current_page == "config" and page.redraw_field then
      if page._fs ~= old_fs then
        self._last_render = 0  -- section changed, full render
      elseif page._ff ~= old_ff then
        -- Field nav: redraw old focus + new focus
        page:redraw_field(old_ff)
        page:redraw_field(page._ff)
      else
        -- Same field: toggle/start-edit
        page:redraw_field(page._ff)
      end
    end
  end
end

-- Wrapper: redraw config field after config modal keystroke
function BrokerUI:_redraw_config_field_wrapper(code, char)
  local page = self._page_instances["config"]
  if not page or not page.redraw_field then return end
  page:redraw_field(page._ff)
end

-----------------------------------------------------------------------
-- Render
-----------------------------------------------------------------------
function BrokerUI:_render()
  local gpu = self._gpu; if not gpu then return end
  local okr, w, h = pcall(gpu.getResolution, gpu)
  if not okr or not w then w, h = 80, 25 end
  if type(w) ~= "number" then w = 80 elseif type(h) ~= "number" then h = 25 end
  w, h = math.max(1, w), math.max(1, h)

  -- Stash dimensions for targeted redraws
  self._w, self._h = w, h

  -- Only clear on page transitions; state updates skip the expensive gpu.fill
  if self._page_dirty then
    -- gpu.fill can fail silently on some OC GPUs — fall back to manual blank-line clear
    local fill_ok = pcall(gpu.fill, gpu, 1, 1, w, h, " ")
    if not fill_ok then
      for cr = 1, h do pcall(gpu.set, gpu, 1, cr, string.rep(" ", w)) end
    end
    self._page_dirty = false
  end

  -- Dispatch to active page instance (h-1 reserves bottom row for footer/help)
  local page = self._page_instances[self._current_page]
  if page and page.render then
    page._w, page._h = w, h - 1  -- update page dimensions
    -- xpcall error boundary: catch page render crashes, log traceback, fall back
    local success, err_msg = xpcall(function()
      page:render()
    end, debug.traceback)
    if not success then
      self._log("[UI RENDER CRASH] page=" .. tostring(self._current_page) .. " " .. tostring(err_msg))
      -- Fall back to logs page (simplest, no broker state needed)
      self._current_page = "logs"
      self._page_dirty = true
      -- Flash error banner at bottom of screen
      local banner = " RENDER ERROR - check logs "
      pcall(gpu.setForeground, 0xFF0000)
      pcall(gpu.setBackground, 0x000000)
      pcall(gpu.set, 1, h, string.rep(" ", w))
      pcall(gpu.set, 1, h, banner)
    end
  end
end

-----------------------------------------------------------------------
-- Headless fallback
-----------------------------------------------------------------------
function BrokerUI:headless_line()
  self:_track_dispatch()
  if not self._rob then return "[Broker] no data" end
  local dbg = self._rob:get_debug(); local pending = self._rob:pending_count()
  local parts = {"buf="..tostring(dbg.buffer_state), "pend="..tostring(pending), "locks="..tostring(dbg.active_locks or 0)}
  local lp = {}; for mid, l in pairs(dbg.lanes or {}) do lp[#lp+1] = ("%s:%s"):format(tostring(mid):sub(1,6), tostring(l.state)) end
  if #lp > 0 then parts[#parts+1] = table.concat(lp, " ") end
  return "[Broker] "..table.concat(parts, " | ")
end

-----------------------------------------------------------------------
-- Main loop (event-first, backend pump gated to 1 Hz)
-----------------------------------------------------------------------
function BrokerUI:run()
  if not self._gpu then
    while true do
      if self._pump_fn then pcall(self._pump_fn) end
      print(self:headless_line())
      os.execute("sleep 1")
    end
  end
  local event = require("event")
  local ok_kb, kb = pcall(require, "keyboard"); self._kb = ok_kb and kb or nil
  if self._screen_addr then pcall(self._gpu.bind, self._screen_addr) end
  local mw, mh = 80, 25
  pcall(function()
    local ok, w, h = pcall(self._gpu.getResolution)
    if ok and w and h then mw, mh = w, h end
  end)
  pcall(self._gpu.setResolution, mw, mh)
  self._running = true; pcall(self._refresh_data, self)
  self._page_dirty = true; pcall(self._render, self)
  local last_pump = 0
  while self._running do
    -- High-frequency event poll: short timeout catches keystrokes instantly
    local ev = { event.pull(0.05) }
    if ev[1] == "key_down" then
      self._ctrl = self._kb and self._kb.isControlDown()
      self:_handle_key(ev[4], ev[3])
    elseif ev[1] == "clipboard" then
      -- Paste clipboard text into active config field
      local text = ev[3]
      if self._current_page == "config" and type(text) == "string" and #text > 0 then
        local page = self._page_instances["config"]
        if page and page._editing and not page._locked then
          page._eb = (page._eb or "") .. text
          if page.redraw_field then page:redraw_field(page._ff) end
        end
      end
    end
    local now = self._now()
    -- Gate backend pump to ~1 Hz — don't block input with dispatch work
    if now - last_pump > 1.0 then
      if self._pump_fn then pcall(self._pump_fn) end
      pcall(self._refresh_data, self)
      last_pump = now
    end
    -- Full render throttled to ~2 fps (0.5s) — GPU is the bottleneck
    if now - (self._last_render or 0) >= 0.5 then
      pcall(self._render, self)
      self._last_render = now
    end
  end
  -- Cleanup on exit
  pcall(self._gpu.fill, self._gpu, 1, 1, mw, mh, " ")
  U.FG(self._gpu, U.W); U.GS(self._gpu, 1, 1, "AutoOS Broker stopped.")
end

return BrokerUI
