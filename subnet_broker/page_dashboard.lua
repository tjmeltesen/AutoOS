-- page_dashboard.lua - Dashboard page: broker status, lane table, pending queue, locks
-- Lua 5.2, OpenComputers. Inherits from BasePage.
-- ponytail: color batching preserved for GPU performance; add lane-detail popup if users ask.

local BasePage = require("class_base_page")
local U = require("ui_utils")
local C = require("ui_components")

local DashboardPage = setmetatable({}, {__index = BasePage})
DashboardPage.__index = DashboardPage
DashboardPage.page_id = "dashboard"

function DashboardPage.new(deps)
  local o = BasePage.new(deps)
  setmetatable(o, DashboardPage)
  o._scroll_offset = 0
  return o
end

function DashboardPage:on_mount()
  self._scroll_offset = 0
end

function DashboardPage:set_data(t)
  if type(t) == "table" then
    for k, v in pairs(t) do
      self.data[k] = v
    end
  end
  -- Preserve scroll_offset across data refreshes
  -- (set_data may pass scroll_offset 0, but we only reset on mount)
end

function DashboardPage:handle_input(event)
  local data = self.data
  local n = 0; for _ in pairs(data.lanes or {}) do n = n + 1 end
  local off = self._scroll_offset or 0
  if event.code == 200 then
    self._scroll_offset = math.max(0, off - 1)
    return true
  elseif event.code == 208 then
    self._scroll_offset = math.min(math.max(0, n - 6), off + 1)
    return true
  end
  return false
end

function DashboardPage:render()
  local gpu = self.deps.gpu; if not gpu then return end
  local w, h = self._w, self._h
  local data = self.data or {}
  local lanes = data.lanes or {}
  local pending = data.pending or {}
  local locks = data.locks or {}
  local now = data.now_fn and data.now_fn() or 0

  -- Row 1: title
  U.FG(gpu, U.GRAY)
  U.GS(gpu, 1, 1, U.pad((" AutoOS Broker -- %s"):format(data.subnet_id or "?"):sub(1, w), w))

  -- Row 2: broker state + uptime + port + jobs
  local active, faulted = 0, 0
  for _, l in pairs(lanes) do
    if l.state == "WORKING" then active = active + 1 elseif l.state == "FAULTED" then faulted = faulted + 1 end
  end
  local bstate = data.broker_active and "RUNNING" or "STOPPED"
  U.FG(gpu, U.GRAY)
  U.GS(gpu, 1, 2, U.pad((" BROKER: %-8s  Uptime: %-6s  Port: %-3s  Jobs: %s"):format(
    bstate, U.format_uptime(data.uptime or 0), tostring(data.port or "?"), tostring(active).."/"..tostring(data.max_lanes or 0)), w))
  U.FG(gpu, data.broker_active and U.G or U.R)
  U.GS(gpu, 9, 2, bstate)

  -- Row 3: status message (if any)
  if data.status then U.FG(gpu, U.CYAN); U.GS(gpu, 1, 3, U.pad(data.status:sub(1, w), w)) end
  local next_row = data.status and 4 or 3
  -- Separator
  U.FG(gpu, U.GRAY); U.GS(gpu, 1, next_row, string.rep("-", w))

  -- Lane Status header
  local r = next_row + 1; U.FG(gpu, U.GRAY); U.GS(gpu, 1, r, U.pad(" Lane Status", w)); r = r + 1
  U.GS(gpu, 1, r, U.pad((" %-14s %-9s %-18s %s"):format("Machine","State","Job","Elapsed"), w)); r = r + 1

  -- Sort lanes by state for color batching: WORKING > FAULTED > IDLE
  local state_order = { WORKING = 1, FAULTED = 2, IDLE = 3 }
  local keys = {}; for k in pairs(lanes) do keys[#keys+1] = k end
  table.sort(keys, function(a, b)
    local sa = (lanes[a] or {}).state or "?"
    local sb = (lanes[b] or {}).state or "?"
    local oa = state_order[sa] or 99
    local ob = state_order[sb] or 99
    if oa ~= ob then return oa < ob end
    return a < b
  end)

  local off = self._scroll_offset or 0; local maxo = math.max(0, #keys - 6)
  if off < 0 then off = 0 elseif off > maxo then off = maxo end
  self._scroll_offset = off

  -- Build visible rows (pre-compute data, no GPU calls yet)
  local visible = {}
  for li = 1 + off, math.min(off + 6, #keys) do
    if r > h - 6 then break end
    local k = keys[li]; local l = lanes[k] or {}; local s = l.state or "?"
    local nm = #k > 14 and k:sub(1,13).."." or k
    local j = l.current_job_id or (s=="FAULTED" and (l.last_error or "?")) or "--"
    if #j > 17 then j = j:sub(1,16).."." end
    local el = "--"; if s=="WORKING" and l.state_entered_at then el = U.format_uptime(now - l.state_entered_at) end
    local full = string.format(" %-14s %-9s %-18s %s", nm, s, j, el)
    visible[#visible + 1] = {
      row = r,
      line_full = U.pad(full, w),
      state_str = s,
      state_color = (s=="WORKING" and U.Y or s=="FAULTED" and U.R or s=="IDLE" and U.G or U.W),
    }
    r = r + 1
  end

  -- Batch render: draw all full rows in GRAY, then overlay state columns grouped by color
  U.FG(gpu, U.GRAY)
  for _, v in ipairs(visible) do
    U.GS(gpu, 1, v.row, v.line_full)
  end

  -- Overlay state labels, batched by color
  local last_sc = nil
  for _, v in ipairs(visible) do
    if v.state_color ~= last_sc then
      U.FG(gpu, v.state_color)
      last_sc = v.state_color
    end
    U.GS(gpu, 17, v.row, v.state_str .. string.rep(" ", 9))
  end

  if #keys == 0 then U.FG(gpu, U.GRAY); U.GS(gpu, 1, r, U.pad(" (no lanes)", w)); r = r + 1 end

  -- Blank any stale lane rows below visible area
  U.FG(gpu, U.GRAY)
  local max_lane_row = next_row + 3 + math.min(6, #keys)
  for cr = r, max_lane_row do
    U.GS(gpu, 1, cr, string.rep(" ", w))
  end

  -- Pending Queue
  r = max_lane_row + 1; U.FG(gpu, U.GRAY); U.GS(gpu, 1, r, U.pad(" Pending Queue", w)); r = r + 1
  if #pending == 0 then U.FG(gpu, U.GRAY); U.GS(gpu, 1, r, U.pad(" (empty)", w)); r = r + 1
  else
    for i = 1, math.min(#pending, 3) do
      if r > h - 4 then break end
      local jb = pending[i] or {}
      local it = (jb.manifest and jb.manifest.items and #jb.manifest.items) or 0
      local fl = (jb.manifest and jb.manifest.fluids and #jb.manifest.fluids) or 0
      U.FG(gpu, U.W)
      U.GS(gpu, 1, r, U.pad((" %-20s  age:%-5s  a:%d  %di/%df"):format(
        (jb.id or "?"):sub(1,20), U.format_ago(now, jb.created_at), jb.attempt or 1, it, fl), w))
      r = r + 1
    end
  end

  -- Active Locks
  r = r + 1; U.FG(gpu, U.GRAY); U.GS(gpu, 1, r, U.pad(" Active Locks", w)); r = r + 1
  local lkeys = {}; for k in pairs(locks) do lkeys[#lkeys+1] = k end
  if #lkeys == 0 then U.FG(gpu, U.GRAY); U.GS(gpu, 1, r, U.pad(" (none)", w)); r = r + 1
  else
    for i = 1, math.min(#lkeys, 3) do
      if r > h - 1 then break end
      local key = lkeys[i]; local disp = U.shorten_uuid(key)
      U.FG(gpu, U.W)
      U.GS(gpu, 1, r, U.pad((" %-47s  %s"):format(disp, locks[key] or "?"), w))
      r = r + 1
    end
  end

  -- Footer nav
  C.draw_footer_nav(self.deps, "[1]Dash  [2]Logs  [3]Config  S:start/stop  Q:quit  Up/Dn:scroll", w, h)
end

return DashboardPage
