-- broker_ui_dashboard.lua - Dashboard page for AutoOS Broker UI
-- Lua 5.2, OpenComputers. Self-sufficient: works with any data, even {}.

local Dashboard = { name = "Dashboard" }

local function fmt_time(seconds)
  if not seconds or seconds < 0 then return "--" end
  if seconds < 60 then return "<1m" end
  local d = math.floor(seconds / 86400)
  local h = math.floor((seconds % 86400) / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = math.floor(seconds % 60)
  if d > 0 then return string.format("%dd%dh", d, h) end
  if h > 0 then return string.format("%dh%dm", h, m) end
  if s > 0 then return string.format("%dm%ds", m, s) end
  return string.format("%dm", m)
end

local function fmt_age(now, t)
  if not now or not t then return "--" end
  local diff = now - t
  if diff < 0 then return "--" end
  if diff < 60 then return math.floor(diff) .. "s"
  elseif diff < 3600 then return math.floor(diff / 60) .. "m"
  else return math.floor(diff / 3600) .. "h" end
end

local G, W, Y, R = 0x00FF00, 0xFFFFFF, 0xFFFF00, 0xFF0000
local GRAY = 0x808080

function Dashboard.render(gpu, w, h, data)
  data = data or {}

  -- ====== ROW 1: Title bar ======
  gpu.setBackground(0x000000)
  gpu.fill(1, 1, w, h, " ")
  gpu.setForeground(GRAY)
  local title = " AutoOS Broker -- " .. (data.subnet_id or "?")
  title = title .. string.rep(" ", w - #title)
  gpu.set(1, 1, title)

  -- ====== ROW 2: Status bar ======
  local lanes = data.lanes or {}
  local active, faulted = 0, 0
  for _, lane in pairs(lanes) do
    if lane.state == "WORKING" then active = active + 1
    elseif lane.state == "FAULTED" then faulted = faulted + 1 end
  end
  local has_any = next(lanes) ~= nil
  local status = "OK"
  local scol = G
  if not has_any then status = "IDLE"
  elseif faulted > 0 and active == 0 then status = "STALLED"; scol = R
  elseif faulted > 0 then status = "WARN"; scol = Y end

  local jobs = tostring(active) .. "/" .. tostring(data.max_lanes or 0)
  local port = tostring(data.port or "?")
  local uptime = fmt_time(data.uptime or 0)
  local status_line = string.format(" STATUS: %-7s  Uptime: %-6s  Port: %-3s  Jobs: %s",
    status, uptime, port, jobs)
  if #status_line > w then status_line = status_line:sub(1, w) end
  gpu.setForeground(GRAY)
  gpu.set(1, 2, status_line)
  gpu.setForeground(scol)
  gpu.set(9, 2, status)  -- color the status word

  -- ====== ROW 3: separator ======
  gpu.setForeground(GRAY)
  gpu.set(1, 3, string.rep("-", w))

  -- ====== ROWS 4-10: Lane Status ======
  local row = 4
  gpu.setForeground(GRAY)
  gpu.set(1, row, " Lane Status")
  row = row + 1
  gpu.setForeground(GRAY)
  gpu.set(1, row, string.format(" %-14s %-9s %-18s %s", "Machine", "State", "Job", "Elapsed"))
  row = row + 1

  local lane_keys = {}
  for k in pairs(lanes) do lane_keys[#lane_keys + 1] = k end
  table.sort(lane_keys)

  local now = data.now_fn and data.now_fn() or 0
  local max_lane_rows = math.min(#lane_keys, 6)
  local off = data.scroll_offset or 0
  if off < 0 then off = 0 end
  if off > math.max(0, #lane_keys - max_lane_rows) then off = math.max(0, #lane_keys - max_lane_rows) end
  data.scroll_offset = off

  for li = 1 + off, math.min(off + max_lane_rows, #lane_keys) do
    if row > h - 6 then break end
    local k = lane_keys[li]
    local lane = lanes[k] or {}
    local name = k:len() > 14 and k:sub(1, 13).."." or (k .. string.rep(" ", 14 - k:len()))
    local state = lane.state or "?"
    local lc = state == "WORKING" and Y or state == "FAULTED" and R or state == "IDLE" and G or W
    local st = (state .. string.rep(" ", 9)):sub(1, 9)
    local job = lane.current_job_id or (state == "FAULTED" and (lane.last_error or "?"):sub(1, 17)) or "--"
    if job:len() > 17 then job = job:sub(1, 16) .. "." end
    job = (job .. string.rep(" ", 18)):sub(1, 18)
    local elapsed = "--"
    if lane.state == "WORKING" and lane.state_entered_at then
      elapsed = fmt_time(now - lane.state_entered_at)
    end
    local line = string.format(" %-14s ", name)
    gpu.setForeground(GRAY); gpu.set(1, row, line)
    gpu.setForeground(lc);    gpu.set(#line + 1, row, st)
    gpu.setForeground(W);     gpu.set(#line + 11, row, job)
    gpu.setForeground(GRAY);  gpu.set(#line + 30, row, elapsed)
    row = row + 1
  end

  if #lane_keys == 0 then
    gpu.setForeground(GRAY)
    gpu.set(1, row, " (no lanes)")
    row = row + 1
  end

  -- ====== Pending Queue ======
  row = row + 1
  gpu.setForeground(GRAY)
  gpu.set(1, row, " Pending Queue")
  row = row + 1
  local pending = data.pending or {}
  if #pending == 0 then
    gpu.set(1, row, " (empty)")
    row = row + 1
  else
    for i = 1, math.min(#pending, 3) do
      if row > h - 4 then break end
      local job = pending[i] or {}
      local items = (job.manifest and job.manifest.items and #job.manifest.items) or 0
      local fluids = (job.manifest and job.manifest.fluids and #job.manifest.fluids) or 0
      local line = string.format(" %-20s  age:%-5s  a:%d  %di/%df",
        (job.id or "?"):sub(1, 20), fmt_age(now, job.created_at),
        job.attempt or 1, items, fluids)
      gpu.set(1, row, line:sub(1, w))
      row = row + 1
    end
  end

  -- ====== Active Locks ======
  row = row + 1
  gpu.setForeground(GRAY)
  gpu.set(1, row, " Active Locks")
  row = row + 1
  local locks = data.locks or {}
  local lock_keys = {}
  for k in pairs(locks) do lock_keys[#lock_keys + 1] = k end
  if #lock_keys == 0 then
    gpu.set(1, row, " (none)")
    row = row + 1
  else
    for i = 1, math.min(#lock_keys, 3) do
      if row > h - 1 then break end
      local key = lock_keys[i]
      -- Truncate long UUIDs
      local display = key:gsub(":(%x%x%x%x%x%x%x%x)%-[%x%-]+", ":%1...")
      if #display > 45 then display = display:sub(1, 44) .. "." end
      local line = string.format(" %-47s  %s", display, locks[key] or "?")
      gpu.set(1, row, line:sub(1, w))
      row = row + 1
    end
  end

  -- ====== Help bar at bottom ======
  gpu.setForeground(GRAY)
  gpu.set(1, h, "[1]Dash  [2]Logs  [3]Config  Tab:next  Q:quit  Up/Dn:scroll")
end

Dashboard.handle_key = function(code, data)
  data = data or {}
  local lanes = data.lanes or {}
  local n_lanes = 0; for _ in pairs(lanes) do n_lanes = n_lanes + 1 end
  local off = data.scroll_offset or 0
  if code == 200 then data.scroll_offset = math.max(0, off - 1)  -- Up
  elseif code == 208 then data.scroll_offset = math.min(math.max(0, n_lanes - 6), off + 1)  -- Down
  end
end

return Dashboard
