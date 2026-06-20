-- broker_ui_dashboard.lua
-- AutoOS Broker UI: Dashboard page
-- Renders status bar, lane status, pending queue, recent dispatches, active locks

local Dashboard = {}
Dashboard.name = "Dashboard"

-- ─── helpers ───────────────────────────────────────────────────────────────

local function truncate(str, max)
  if not str then
    return "—"
  end
  if #str <= max then
    return str
  end
  return str:sub(1, max - 3) .. "..."
end

local function fmt_time(seconds)
  if seconds == nil or seconds < 0 then
    return "—"
  end
  if seconds < 60 then
    return "<1m"
  end
  local d = math.floor(seconds / 86400)
  local h = math.floor((seconds % 86400) / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = math.floor(seconds % 60)
  if d > 0 then
    return string.format("%dd %dh", d, h)
  end
  if h > 0 then
    return string.format("%dh %dm", h, m)
  end
  if s > 0 then
    return string.format("%dm %ds", m, s)
  end
  return string.format("%dm", m)
end

local function fmt_age(now, then_time)
  if not then_time then
    return "—"
  end
  local diff = now - then_time
  if diff < 0 then
    return "—"
  end
  if diff < 60 then
    return math.floor(diff) .. "s ago"
  end
  if diff < 3600 then
    return math.floor(diff / 60) .. "m ago"
  end
  return math.floor(diff / 3600) .. "h ago"
end

-- ─── local constants ───────────────────────────────────────────────────────

-- Box drawing characters
local H = "─"
local V = "│"
local TL = "┌"
local TR = "┐"
local BL = "└"
local BR = "┘"
local LT = "├"
local RT = "┤"

-- Colors (OpenComputers palette indices)
local COLOR_GRAY = 0x666666
local COLOR_WHITE = 0xFFFFFF
local COLOR_GREEN = 0x00FF00
local COLOR_YELLOW = 0xFFFF00
local COLOR_RED = 0xFF0000

-- ─── section: status bar ───────────────────────────────────────────────────

local function render_status_bar(gpu, w, h, data, start_row)
  local row = start_row
  local subnet_id = data.subnet_id or "unknown"
  local uptime = data.uptime or 0
  local port = data.port or 0
  local lanes = data.lanes or {}
  local max_lanes = data.max_lanes or 0

  -- Count states
  local active_count = 0
  local faulted_count = 0
  local has_any = false
  for _, lane in pairs(lanes) do
    has_any = true
    if lane.state == "WORKING" then
      active_count = active_count + 1
    elseif lane.state == "FAULTED" then
      faulted_count = faulted_count + 1
    end
  end

  local status_str, status_color
  if not has_any then
    status_str = "OK"
    status_color = COLOR_GREEN
  elseif faulted_count > 0 and active_count == 0 then
    status_str = "STALLED"
    status_color = COLOR_RED
  elseif faulted_count > 0 then
    status_str = "DEGRADED"
    status_color = COLOR_YELLOW
  else
    status_str = "OK"
    status_color = COLOR_GREEN
  end

  local job_str = tostring(active_count) .. "/" .. tostring(max_lanes)

  -- Row 1: top border with title
  local top_line = TL .. " AutoOS Broker ── " .. subnet_id
  local filler = w - #top_line - 1
  if filler > 0 then
    top_line = top_line .. string.rep(H, filler)
  end
  top_line = top_line .. TR

  gpu.setForeground(COLOR_GRAY)
  gpu.set(row, 1, top_line:sub(1, w))

  -- Row 2: status line
  row = row + 1
  local status_line = V .. " STATUS: "
  gpu.setForeground(COLOR_GRAY)
  gpu.set(row, 1, V)
  gpu.set(row, 2, " STATUS: ")

  -- STATUS value in color
  gpu.setForeground(status_color)
  gpu.set(row, #status_line + 1, status_str)

  -- Uptime
  gpu.setForeground(COLOR_GRAY)
  local uptime_part = "    Uptime: "
  local uptime_pos = #status_line + #status_str + 1
  gpu.set(row, uptime_pos, uptime_part)
  gpu.setForeground(COLOR_WHITE)
  uptime_pos = uptime_pos + #uptime_part
  gpu.set(row, uptime_pos, fmt_time(uptime))

  -- Port
  gpu.setForeground(COLOR_GRAY)
  uptime_pos = uptime_pos + #fmt_time(uptime)
  local port_part = "    Port: "
  gpu.set(row, uptime_pos, port_part)
  gpu.setForeground(COLOR_WHITE)
  uptime_pos = uptime_pos + #port_part
  gpu.set(row, uptime_pos, tostring(port))

  -- Jobs
  gpu.setForeground(COLOR_GRAY)
  uptime_pos = uptime_pos + #tostring(port)
  local jobs_part = "    Jobs: "
  gpu.set(row, uptime_pos, jobs_part)
  gpu.setForeground(COLOR_WHITE)
  uptime_pos = uptime_pos + #jobs_part
  gpu.set(row, uptime_pos, job_str)

  -- Pad rest of line with spaces
  gpu.setForeground(COLOR_GRAY)
  local right_pad = w - uptime_pos - #job_str
  if right_pad > 0 then
    gpu.set(row, uptime_pos + #job_str, string.rep(" ", right_pad - 1) .. V)
  else
    gpu.set(row, w, V)
  end

  return row
end

-- ─── section: lane status ──────────────────────────────────────────────────

local function render_lane_status(gpu, w, h, data, start_row)
  local row = start_row
  local lanes = data.lanes or {}
  local now = (data.now_fn or os.clock)()
  local scroll_offset = data.scroll_offset or 0

  gpu.setForeground(COLOR_GRAY)

  -- Blank separator line
  gpu.set(row, 1, V .. string.rep(" ", w - 2) .. V)
  row = row + 1

  -- Section header
  gpu.set(row, 1, LT .. " Lane Status " .. string.rep(H, w - #(" Lane Status ") - 1) .. RT)
  row = row + 1

  -- Column headers
  local header_line = V
    .. string.format(" %-15s", "Machine")
    .. string.format(" %-10s", "State")
    .. string.format(" %-20s", "Job ID")
    .. " Elapsed    "
  local header_pad = w - #header_line - 1
  if header_pad > 0 then
    header_line = header_line .. string.rep(" ", header_pad)
  end
  header_line = header_line .. V
  gpu.set(row, 1, header_line:sub(1, w))
  row = row + 1

  -- Collect lane keys sorted
  local lane_keys = {}
  for k, _ in pairs(lanes) do
    lane_keys[#lane_keys + 1] = k
  end
  table.sort(lane_keys)

  -- How many lane rows we can show (leave room for blank line after)
  local max_visible = h - row - 2
  if max_visible < 0 then
    max_visible = 0
  end
  max_visible = math.min(max_visible, #lane_keys)

  local total_lanes = #lane_keys
  if total_lanes > max_visible then
    if scroll_offset < 0 then
      scroll_offset = 0
    end
    if scroll_offset > total_lanes - max_visible then
      scroll_offset = total_lanes - max_visible
    end
    data.scroll_offset = scroll_offset
  else
    scroll_offset = 0
    data.scroll_offset = 0
  end

  -- Show scroll up indicator if needed
  if scroll_offset > 0 then
    gpu.setForeground(COLOR_GRAY)
    gpu.set(row, 1, V .. "  ... more above ..." .. string.rep(" ", w - 20) .. V)
    row = row + 1
  end

  for i = scroll_offset + 1, math.min(scroll_offset + max_visible, total_lanes) do
    local key = lane_keys[i]
    local lane = lanes[key]
    local machine_name = truncate(key, 15)

    -- State color
    local state_color = COLOR_WHITE
    if lane.state == "WORKING" then
      state_color = COLOR_YELLOW
    elseif lane.state == "IDLE" then
      state_color = COLOR_GREEN
    elseif lane.state == "FAULTED" then
      state_color = COLOR_RED
    end

    -- Job ID column
    local job_id_col
    if lane.state == "FAULTED" then
      job_id_col = truncate(lane.last_error or "unknown", 18)
    elseif lane.current_job_id then
      job_id_col = truncate(lane.current_job_id, 20)
    else
      job_id_col = "—"
    end

    -- Elapsed
    local elapsed
    if lane.state == "WORKING" and lane.deadline and lane.state_entered_at then
      -- Use time since state_entered_at if available, otherwise since deadline
      local since = lane.state_entered_at
      elapsed = fmt_time(now - since)
    else
      elapsed = "—"
    end

    -- Build the line
    gpu.setForeground(COLOR_GRAY)
    gpu.set(row, 1, V)
    gpu.set(row, 2, " " .. string.format("%-15s", machine_name))

    gpu.setForeground(state_color)
    gpu.set(row, 19, string.format("%-10s", lane.state or "—"))

    gpu.setForeground(COLOR_WHITE)
    gpu.set(row, 30, string.format("%-20s", job_id_col))

    gpu.setForeground(COLOR_WHITE)
    gpu.set(row, 51, string.format("%-10s", elapsed))

    gpu.setForeground(COLOR_GRAY)
    gpu.set(row, w, V)

    row = row + 1
  end

  -- Show scroll down indicator if needed
  if scroll_offset + max_visible < total_lanes then
    gpu.setForeground(COLOR_GRAY)
    gpu.set(row, 1, V .. "  ... more below ..." .. string.rep(" ", w - 20) .. V)
    row = row + 1
  end

  -- Fill remaining rows with blank lines to section boundary
  local bottom_marker_row = start_row + (h - start_row)
  -- We'll let the caller handle remaining blank filler between sections

  return row
end

-- ─── section: pending queue ────────────────────────────────────────────────

local function render_pending_queue(gpu, w, h, data, start_row, max_rows)
  local row = start_row
  local pending = data.pending or {}
  local now = (data.now_fn or os.clock)()
  local visible = math.min(max_rows or 5, 8)

  gpu.setForeground(COLOR_GRAY)

  -- Section header
  gpu.set(row, 1, LT .. " Pending Queue " .. string.rep(H, w - #(" Pending Queue ") - 1) .. RT)
  row = row + 1

  if #pending == 0 then
    gpu.set(row, 1, V .. " (empty)" .. string.rep(" ", w - #(" (empty)") - 1) .. V)
    row = row + 1
  else
    -- Column headers
    local header = V .. " #  "
      .. string.format("%-20s", "Job ID")
      .. string.format("%-8s", "Age")
      .. string.format("%-4s", "Att")
      .. " Items     "
    local header_pad = w - #header - 1
    if header_pad > 0 then
      header = header .. string.rep(" ", header_pad)
    end
    header = header .. V
    gpu.set(row, 1, header:sub(1, w))
    row = row + 1

    for i = 1, math.min(visible, #pending) do
      local job = pending[i]
      local idx_str = string.format("%-3d", i)
      local job_id = truncate(job.id or "?", 20)
      local age = fmt_age(now, job.created_at)
      local attempt = tostring(job.attempt or 1)

      -- Items / fluids counts
      local items_count = 0
      local fluids_count = 0
      if job.manifest then
        if job.manifest.items then
          items_count = #job.manifest.items
        end
        if job.manifest.fluids then
          fluids_count = #job.manifest.fluids
        end
      end
      local items_str = tostring(items_count) .. "i/" .. tostring(fluids_count) .. "f"

      -- Build line
      gpu.setForeground(COLOR_GRAY)
      gpu.set(row, 1, V)

      gpu.setForeground(COLOR_WHITE)
      gpu.set(row, 3, idx_str)

      gpu.setForeground(COLOR_WHITE)
      gpu.set(row, 7, string.format("%-20s", job_id))

      gpu.setForeground(COLOR_WHITE)
      gpu.set(row, 28, string.format("%-8s", age))

      gpu.setForeground(COLOR_WHITE)
      gpu.set(row, 37, string.format("%-4s", attempt))

      gpu.setForeground(COLOR_WHITE)
      gpu.set(row, 42, items_str)

      gpu.setForeground(COLOR_GRAY)
      gpu.set(row, w, V)

      row = row + 1
    end
  end

  return row
end

-- ─── section: recent dispatches ────────────────────────────────────────────

local function render_dispatch_log(gpu, w, h, data, start_row, max_rows)
  local row = start_row
  local dispatch_log = data.dispatch_log or {}
  local now = (data.now_fn or os.clock)()
  local visible = math.min(max_rows or 5, 8)

  gpu.setForeground(COLOR_GRAY)

  -- Section header
  gpu.set(row, 1, LT .. " Recent Dispatches " .. string.rep(H, w - #(" Recent Dispatches ") - 1) .. RT)
  row = row + 1

  if #dispatch_log == 0 then
    gpu.set(row, 1, V .. " (none)" .. string.rep(" ", w - #(" (none)") - 1) .. V)
    row = row + 1
  else
    -- Newest first: iterate from end
    local shown = 0
    for i = #dispatch_log, 1, -1 do
      if shown >= visible then
        break
      end
      local entry = dispatch_log[i]
      local job_id = truncate(entry.job_id or "?", 20)

      -- Determine the machine identifier
      local machine_str = truncate(entry.machine_id or "?", 15)

      -- Age
      local age_str
      if entry.time then
        age_str = fmt_age(now, entry.time)
      else
        age_str = "—"
      end

      -- Status color
      local status_color = COLOR_WHITE
      local status_str = entry.status or "unknown"
      if status_str == "running" then
        status_color = COLOR_YELLOW
      elseif status_str == "done" then
        status_color = COLOR_GREEN
      elseif status_str == "failed" then
        status_color = COLOR_RED
      end

      -- Build line: "job_id → machine  age  status"
      local line = " "
      line = line .. string.format("%-20s", job_id)
      line = line .. " → "
      line = line .. string.format("%-15s", machine_str)
      line = line .. string.format("%-8s", age_str)

      gpu.setForeground(COLOR_GRAY)
      gpu.set(row, 1, V)

      gpu.setForeground(COLOR_WHITE)
      gpu.set(row, 2, line)

      gpu.setForeground(status_color)
      gpu.set(row, 2 + #line, status_str)

      gpu.setForeground(COLOR_GRAY)
      gpu.set(row, w, V)

      row = row + 1
      shown = shown + 1
    end
  end

  return row
end

-- ─── section: active locks ─────────────────────────────────────────────────

local function render_active_locks(gpu, w, h, data, start_row, max_rows)
  local row = start_row
  local locks = data.locks or {}
  local visible = math.min(max_rows or 4, 6)

  gpu.setForeground(COLOR_GRAY)

  -- Section header
  gpu.set(row, 1, LT .. " Active Locks " .. string.rep(H, w - #(" Active Locks ") - 1) .. RT)
  row = row + 1

  -- Collect lock keys sorted
  local lock_keys = {}
  for k, _ in pairs(locks) do
    lock_keys[#lock_keys + 1] = k
  end
  table.sort(lock_keys)

  if #lock_keys == 0 then
    gpu.set(row, 1, V .. " (no locks held)" .. string.rep(" ", w - #(" (no locks held)") - 1) .. V)
    row = row + 1
  else
    for i = 1, math.min(visible, #lock_keys) do
      local resource_key = lock_keys[i]
      local holder = locks[resource_key] or "?"

      -- Truncate UUID portion: show prefix + first 8 chars of UUID + "..."
      local display_key = resource_key
      -- Try to find a UUID pattern and shorten it
      local uuid_start = resource_key:find(":%x%x%x%x%x%x%x%x%-")
      if uuid_start then
        local prefix = resource_key:sub(1, uuid_start)
        local uuid_prefix = resource_key:sub(uuid_start + 1, uuid_start + 8)
        display_key = prefix .. uuid_prefix .. "..."
      elseif #display_key > 30 then
        display_key = display_key:sub(1, 27) .. "..."
      end

      local line = " " .. string.format("%-35s", display_key) .. string.format("%-15s", holder)

      gpu.setForeground(COLOR_GRAY)
      gpu.set(row, 1, V)

      gpu.setForeground(COLOR_WHITE)
      gpu.set(row, 2, line)

      gpu.setForeground(COLOR_GRAY)
      gpu.set(row, w, V)

      row = row + 1
    end
  end

  return row
end

-- ─── bottom border ─────────────────────────────────────────────────────────

local function render_bottom_border(gpu, w, row)
  gpu.setForeground(COLOR_GRAY)
  gpu.set(row, 1, BL .. string.rep(H, w - 2) .. BR)
  row = row + 1
  return row
end

-- ─── page render ───────────────────────────────────────────────────────────

function Dashboard.render(gpu, w, h, data)
  local row = 1

  -- Section 1: Status Bar (rows 1-2, plus blank line)
  row = render_status_bar(gpu, w, h, data, row)
  row = row + 1  -- blank separator line handled inside status_bar

  -- Section 2: Lane Status
  -- Calculate how much space we have and be flexible
  local lanes = data.lanes or {}
  local lane_keys_count = 0
  for _ in pairs(lanes) do
    lane_keys_count = lane_keys_count + 1
  end
  -- Lane section needs: header (1) + column headers (1) + lane rows + scroll indicators + blank line
  local lane_overhead = 4
  local lane_rows_needed = math.min(lane_keys_count, 8) + lane_overhead
  local remaining = h - row - lane_rows_needed

  -- If lots of space, give lanes up to 10 visible rows; reserve space for below sections
  local lane_max = math.min(lane_keys_count + lane_overhead, math.max(4, h - row - 12))
  row = render_lane_status(gpu, w, h, data, row)

  -- Ensure row advances properly past lane section
  if row >= h - 5 then
    -- Not enough room for remaining sections; just do bottom border
    row = render_bottom_border(gpu, w, row)
    return
  end

  -- Section 3: Pending Queue (up to 5 visible rows + header)
  local pq_max = math.min(6, h - row - 8)
  row = render_pending_queue(gpu, w, h, data, row, pq_max)

  if row >= h - 3 then
    row = render_bottom_border(gpu, w, row)
    return
  end

  -- Section 4: Recent Dispatches (up to 5 visible rows + header)
  local dl_max = math.min(6, h - row - 6)
  row = render_dispatch_log(gpu, w, h, data, row, dl_max)

  if row >= h - 3 then
    row = render_bottom_border(gpu, w, row)
    return
  end

  -- Section 5: Active Locks (up to 4 visible rows + header)
  local al_max = math.min(5, h - row - 2)
  row = render_active_locks(gpu, w, h, data, row, al_max)

  -- Fill remaining rows with blank bordered lines
  gpu.setForeground(COLOR_GRAY)
  while row < h do
    gpu.set(row, 1, V .. string.rep(" ", w - 2) .. V)
    row = row + 1
  end

  -- Bottom border
  render_bottom_border(gpu, w, row)
end

-- ─── key handling ──────────────────────────────────────────────────────────

-- Key codes:
-- Up(200), Down(208), PageUp(201), PageDown(209)

Dashboard.handle_key = function(code, data)
  local lanes = data.lanes or {}
  local lane_count = 0
  for _ in pairs(lanes) do
    lane_count = lane_count + 1
  end

  if code == 200 then -- Up
    local offset = data.scroll_offset or 0
    if offset > 0 then
      data.scroll_offset = offset - 1
    end
  elseif code == 208 then -- Down
    local offset = data.scroll_offset or 0
    -- Allow scrolling to show all lanes
    local max_scroll = math.max(0, lane_count - 8)
    if offset < max_scroll then
      data.scroll_offset = offset + 1
    end
  elseif code == 201 then -- PageUp
    local offset = data.scroll_offset or 0
    data.scroll_offset = math.max(0, offset - 5)
  elseif code == 209 then -- PageDown
    local offset = data.scroll_offset or 0
    local max_scroll = math.max(0, lane_count - 8)
    data.scroll_offset = math.min(max_scroll, offset + 5)
  end
  -- Other keys ignored
end

return Dashboard
