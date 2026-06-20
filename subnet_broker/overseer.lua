--[[
  AutoOS — Overseer TUI Page Manager

  A GPU-backed status display and navigation system for the AutoOS broker.
  Provides three pages: dashboard, logs, config. Falls back to headless
  mode when no GPU is available.

  Page modules (dashboard, logs, config) are loaded via pcall(require, ...)
  so missing pages do not crash the overseer — they simply show a placeholder.

  Usage:
    local Overseer = require("overseer")
    local ov = Overseer.new(rob, config, { gpu = ..., screen_addr = ..., now_fn = ..., log = ... })
    ov:run()
]]

local Overseer = {}
Overseer.__index = Overseer

---------------------------------------------------------------------------
-- OC palette indices (0xRRGGBB)
---------------------------------------------------------------------------

local COLORS = {
  green   = 0x00FF00,
  yellow  = 0xFFFF00,
  red     = 0xFF0000,
  gray    = 0x808080,
  white   = 0xFFFFFF,
  cyan    = 0x00FFFF,
}

---------------------------------------------------------------------------
-- Keyboard codes (OpenComputers)
---------------------------------------------------------------------------

local KEY = {
  ESCAPE    = 1,
  NUM1      = 2,
  NUM2      = 3,
  NUM3      = 4,
  BACKSPACE = 14,
  TAB       = 15,
  Q         = 16,
  ENTER     = 28,
  UP        = 200,
  DOWN      = 208,
  PAGEUP    = 201,
  PAGEDOWN  = 209,
  HOME      = 199,
  END_KEY   = 207,
}

---------------------------------------------------------------------------
-- Box-drawing characters
---------------------------------------------------------------------------

local BOX = {
  H    = "\226\148\128",  -- ─
  V    = "\226\148\130",  -- │
  TL   = "\226\148\140",  -- ┌
  TR   = "\226\148\144",  -- ┐
  BL   = "\226\148\148",  -- └
  BR   = "\226\148\152",  -- ┘
  TL_D = "\226\148\156",  -- ├
  TR_D = "\226\148\164",  -- ┤
}

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local PAGE_ORDER = { "dashboard", "logs", "config" }
local MAX_DISPATCH_LOG = 50
local LOG_PATH = "/var/log/autoos/lane_worker.log"

---------------------------------------------------------------------------
-- Color / drawing helpers
---------------------------------------------------------------------------

local function draw_text(gpu, x, y, color, str)
  if not gpu then return end
  gpu.setForeground(color)
  gpu.set(x, y, tostring(str or ""))
end

local function draw_box(gpu, x, y, w, h, color, title)
  if not gpu then return end
  if w < 3 or h < 2 then return end
  local tw = w - 2 -- inner width
  gpu.setForeground(color)

  -- Top border
  gpu.set(x, y, BOX.TL .. string.rep(BOX.H, tw) .. BOX.TR)
  if title then
    gpu.set(x + 2, y, title)
  end

  -- Side borders for intermediate rows
  for row = y + 1, y + h - 2 do
    gpu.set(x, row, BOX.V)
    gpu.set(x + w - 1, row, BOX.V)
  end

  -- Bottom border
  gpu.set(x, y + h - 1, BOX.BL .. string.rep(BOX.H, tw) .. BOX.BR)
end

---------------------------------------------------------------------------
-- Constructor
---------------------------------------------------------------------------

--- Create a new Overseer page manager.
--- @param rob     table   ROBDispatcher instance
--- @param config  table   Validated Config table
--- @param deps    table   Runtime dependencies
---   deps.gpu          component.gpu proxy (or nil for headless)
---   deps.screen_addr  screen address string (or nil)
---   deps.now_fn       function() -> seconds (os.clock or computer.uptime)
---   deps.log          function(msg) (print)
---   deps.pump_fn      function() called before each render tick (optional)
--- @return Overseer
function Overseer.new(rob, config, deps)
  deps = deps or {}

  local self = setmetatable({}, Overseer)

  self._rob = rob
  self._config = config or {}
  self._gpu = deps.gpu
  self._screen_addr = deps.screen_addr
  self._now = deps.now_fn or os.clock
  self._log = deps.log or print
  self._pump_fn = deps.pump_fn

  self._current_page = "dashboard"
  self._page_idx = 1
  self._pages = {}
  self._dispatch_log = {}
  self._prev_lane_states = {} -- { [machine_id] = state_string }
  self._running = false

  self:_load_pages()

  return self
end

---------------------------------------------------------------------------
-- Page loading
---------------------------------------------------------------------------

function Overseer:_load_pages()
  for _, name in ipairs(PAGE_ORDER) do
    local mod_name = "overseer_" .. name
    local ok, mod = pcall(require, mod_name)
    if ok and mod then
      self._pages[name] = mod
      self._log("[Overseer] loaded page: " .. name)
    else
      self._log("[Overseer] page not available: " .. mod_name)
    end
  end
end

---------------------------------------------------------------------------
-- Dispatch ring buffer
---------------------------------------------------------------------------

--- Track lane state transitions (WORKING->IDLE, IDLE->WORKING, *->FAULTED).
--- Called before each render to detect changes in rob:get_debug().lanes.
function Overseer:_track_dispatch()
  local dbg = self._rob:get_debug()
  local lanes = dbg.lanes or {}

  for mid, lane in pairs(lanes) do
    local prev = self._prev_lane_states[mid]
    local curr = lane.state

    if prev and prev ~= curr then
      local entry = {
        job_id = lane.current_job_id,
        machine_id = mid,
        time = self._now(),
      }
      if curr == "WORKING" then
        entry.status = "running"
      elseif curr == "IDLE" then
        entry.status = prev == "WORKING" and "done" or "idle"
      elseif curr == "FAULTED" then
        entry.status = "failed"
      else
        entry.status = curr
      end
      self._dispatch_log[#self._dispatch_log + 1] = entry

      -- Trim to last N entries
      while #self._dispatch_log > MAX_DISPATCH_LOG do
        table.remove(self._dispatch_log, 1)
      end
    end

    self._prev_lane_states[mid] = curr
  end
end

---------------------------------------------------------------------------
-- Data builders (called before each render for the current page)
---------------------------------------------------------------------------

function Overseer:_build_dashboard_data()
  local dbg = self._rob:get_debug()
  return {
    lanes = dbg.lanes,
    pending = self._rob:pending_queue(),
    locks = self._rob:get_locks(),
    dispatch_log = self._dispatch_log,
    debug = dbg,
  }
end

function Overseer:_read_log_lines(max_lines)
  max_lines = max_lines or 500
  local f, err = io.open(LOG_PATH, "r")
  if not f then
    return { "[log file not available: " .. tostring(err) .. "]" }
  end

  -- Read all lines, keep only the last max_lines
  local all = {}
  for line in f:lines() do
    all[#all + 1] = line
  end
  f:close()

  local start = math.max(1, #all - max_lines + 1)
  local lines = {}
  for i = start, #all do
    lines[#lines + 1] = all[i]
  end
  return lines
end

function Overseer:_build_logs_data()
  return { lines = self:_read_log_lines(500) }
end

function Overseer:_build_config_fields(config_tbl)
  config_tbl = config_tbl or self._config
  local fields = {}

  local function walk(t, prefix)
    for k, v in pairs(t) do
      local full_key = prefix and (prefix .. "." .. k) or k
      local vt = type(v)
      if vt == "table" then
        walk(v, full_key)
      elseif vt == "function" then
        fields[#fields + 1] = { key = full_key, value = "(function)" }
      elseif vt == "boolean" then
        fields[#fields + 1] = { key = full_key, value = v and "true" or "false" }
      elseif vt == "nil" then
        fields[#fields + 1] = { key = full_key, value = "nil" }
      else
        fields[#fields + 1] = { key = full_key, value = tostring(v) }
      end
    end
  end

  walk(config_tbl, nil)

  table.sort(fields, function(a, b) return a.key < b.key end)
  return fields
end

function Overseer:_build_config_data()
  return { fields = self:_build_config_fields(self._config) }
end

---------------------------------------------------------------------------
-- Data refresh
---------------------------------------------------------------------------

--- Refresh the current page's .data field by pulling fresh state from
--- rob and config. Calls _track_dispatch first so the dispatch log is
--- up-to-date.
function Overseer:_refresh_data()
  self:_track_dispatch()

  local page = self._pages[self._current_page]
  if not page then return end

  if self._current_page == "dashboard" then
    page.data = self:_build_dashboard_data()
  elseif self._current_page == "logs" then
    page.data = self:_build_logs_data()
  elseif self._current_page == "config" then
    page.data = self:_build_config_data()
  end
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

function Overseer:_nav_to(name)
  if self._pages[name] then
    self._current_page = name
    for i, n in ipairs(PAGE_ORDER) do
      if n == name then self._page_idx = i; break end
    end
    self:_refresh_data()
  end
end

function Overseer:_nav_next()
  local idx = self._page_idx + 1
  if idx > #PAGE_ORDER then idx = 1 end
  self:_nav_to(PAGE_ORDER[idx])
end

function Overseer:_nav_prev()
  local idx = self._page_idx - 1
  if idx < 1 then idx = #PAGE_ORDER end
  self:_nav_to(PAGE_ORDER[idx])
end

---------------------------------------------------------------------------
-- Key handling
---------------------------------------------------------------------------

function Overseer:_handle_key(code)
  -- Direct page navigation
  if code == KEY.NUM1 then
    self:_nav_to("dashboard")
    return
  elseif code == KEY.NUM2 then
    self:_nav_to("logs")
    return
  elseif code == KEY.NUM3 then
    self:_nav_to("config")
    return
  end

  -- Tab: next page
  if code == KEY.TAB then
    self:_nav_next()
    return
  end

  -- Q or Escape: quit
  if code == KEY.Q or code == KEY.ESCAPE then
    self._running = false
    return
  end

  -- Route remaining keys to the current page's handler
  local page = self._pages[self._current_page]
  if page and page.handle_key then
    page.handle_key(code, page.data)
  end
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

--- Draw the help bar at the bottom row of the screen.
function Overseer:_draw_help_bar(gpu, w, h)
  local help = "[1]Dashboard  [2]Logs  [3]Config   Tab:next   Q:quit"
  if #help > w then
    help = help:sub(1, w)
  else
    help = help .. string.rep(" ", w - #help)
  end
  gpu.setForeground(COLORS.gray)
  gpu.set(1, h, help)
end

--- Full render: clear screen, render current page above help bar, draw help bar.
function Overseer:_render()
  local gpu = self._gpu
  if not gpu then return end

  local w, h = gpu.getResolution()
  local page = self._pages[self._current_page]

  -- Clear
  gpu.fill(1, 1, w, h, " ")

  if page and page.render then
    -- Page renders into rows 1..h-1 (help bar uses row h)
    page.render(gpu, w, h - 1, page.data)
  else
    -- Placeholder for missing page
    gpu.setForeground(COLORS.red)
    gpu.set(2, 2, "Page '" .. self._current_page .. "' not loaded")
    gpu.setForeground(COLORS.gray)
    gpu.set(2, 3, "Create overseer_" .. self._current_page .. ".lua to enable this page.")
  end

  -- Help bar at the bottom
  self:_draw_help_bar(gpu, w, h)
end

---------------------------------------------------------------------------
-- Headless fallback
---------------------------------------------------------------------------

--- Return a one-line string with key broker status suitable for print().
--- @return string
function Overseer:headless_line()
  self:_track_dispatch()
  local dbg = self._rob:get_debug()
  local pending = self._rob:pending_count()

  local parts = {
    "buf=" .. tostring(dbg.buffer_state),
    "pending=" .. tostring(pending),
    "locks=" .. tostring(dbg.active_locks or 0),
  }

  -- Compact lane status
  local lane_parts = {}
  for mid, lane in pairs(dbg.lanes or {}) do
    lane_parts[#lane_parts + 1] = string.format("%s:%s",
      tostring(mid):sub(1, 6),
      tostring(lane.state))
  end
  if #lane_parts > 0 then
    parts[#parts + 1] = table.concat(lane_parts, " ")
  end

  return "[Overseer] " .. table.concat(parts, " | ")
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------

--- Enter the overseer event loop. Blocks until the user presses Q or Escape.
--- If no GPU is available, runs in headless mode (prints status every 1s).
function Overseer:run()
  if not self._gpu then
    -- Headless mode — infinite print loop
    while true do
      if self._pump_fn then self._pump_fn() end
      print(self:headless_line())
      os.execute("sleep 1")
    end
  end

  local event = require("event")

  -- Bind screen
  if self._screen_addr then
    self._gpu.bind(self._screen_addr)
  end

  -- Set resolution (80x25 or detected max)
  local mw, mh = 80, 25
  local ok_max, max_w, max_h = pcall(self._gpu.maxResolution, self._gpu)
  if ok_max then
    mw = math.min(mw, max_w or mw)
    mh = math.min(mh, max_h or mh)
  end
  self._gpu.setResolution(mw, mh)

  -- Initial paint
  self._running = true
  self:_refresh_data()
  self:_render()

  -- Event loop
  while self._running do
    -- Pump broker state before waiting
    if self._pump_fn then self._pump_fn() end

    -- Refresh data and re-render
    self:_refresh_data()
    self:_render()

    -- Wait for key press with 1s timeout
    local ev = { event.pull(1.0, "key_down") }
    local ev_name = ev[1]

    if ev_name == "key_down" then
      -- ev[2]=address, ev[3]=char, ev[4]=code, ev[5]=player_name
      local code = ev[4]
      self:_handle_key(code)
    end
    -- On timeout (nil event), just loop back and refresh
  end

  -- Clean exit: clear screen and print stop message
  self._gpu.fill(1, 1, mw, mh, " ")
  self._gpu.setForeground(COLORS.white)
  self._gpu.set(1, 1, "AutoOS Overseer stopped.")
end

return Overseer
