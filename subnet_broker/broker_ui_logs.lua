-- broker_ui_logs.lua - Log viewer page for AutoOS Broker UI
-- Lua 5.2, OpenComputers
--
-- Returns: { name = "Logs", render = fn, handle_key = fn, load_log_lines = fn }

local BOX_L = "\226\148\156"  -- ├
local BOX_R = "\226\148\164"  -- ┤
local BOX_H = "\226\148\128"  -- ─

local module = {}

module.name = "Logs"

---------------------------------------------------------------------------
-- load_log_lines(path[, max_lines]) -> {string, ...}
-- Reads a file and returns the last max_lines lines (default 1000).
---------------------------------------------------------------------------
function module.load_log_lines(path, max_lines)
  max_lines = max_lines or 1000
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  -- Trim to last max_lines
  if #lines > max_lines then
    local trimmed = {}
    local start = #lines - max_lines + 1
    for i = start, #lines do
      trimmed[#trimmed + 1] = lines[i]
    end
    return trimmed
  end
  return lines
end

---------------------------------------------------------------------------
-- render(gpu, w, h, data)
-- Draws the log viewer page.
---------------------------------------------------------------------------
function module.render(gpu, w, h, data)
  if not data then return end
  data.path = data.path or "/var/log/autoos/lane_worker.log"
  data.lines = data.lines or {}
  -- Follow mode: always pin to newest lines
  if data.follow then
    data.offset = 0
  end

  -- ------------------------------------------------------------------
  -- Clear screen
  -- ------------------------------------------------------------------
  gpu.setBackground(0x000000)
  gpu.fill(1, 1, w, h, " ")

  -- ------------------------------------------------------------------
  -- Row 1: header bar
  --   "├─ Logs ── <path> ────…────┤"  (gray)
  -- ------------------------------------------------------------------
  gpu.setForeground(0x808080)
  gpu.setBackground(0x000000)

  -- Build header: prefix (12 display columns) + path + filler + "┤"
  -- prefix = ├─ Logs ──  + space = 12 display columns
  local prefix = BOX_L .. BOX_H .. " Logs " .. BOX_H .. BOX_H .. " "
  local prefix_cols = 12
  local filler_needed = w - prefix_cols - #data.path

  if filler_needed <= 1 then
    -- Path is too long; truncate to fit, leaving room for "┤"
    local avail = w - prefix_cols - 2
    if avail < 1 then
      avail = 1
    end
    local short_path = string.sub(data.path, 1, avail)
    -- Recalculate filler after truncation
    local rem = w - prefix_cols - #short_path
    if rem <= 1 then
      -- Still tight: squeeze without filler, just path + ┤
      gpu.set(1, 1, prefix .. short_path .. BOX_R)
    else
      gpu.set(1, 1, prefix .. short_path .. " " .. string.rep(BOX_H, rem - 2) .. BOX_R)
    end
  else
    gpu.set(1, 1, prefix .. data.path .. " " .. string.rep(BOX_H, filler_needed - 2) .. BOX_R)
  end

  -- ------------------------------------------------------------------
  -- No-lines case: centre "(no log file)"
  -- ------------------------------------------------------------------
  if not data.lines or #data.lines == 0 then
    gpu.setForeground(0x808080)
    local msg = "(no log file)"
    local msg_x = math.floor((w - #msg) / 2) + 1
    local msg_y = math.floor(h / 2)
    if msg_x < 1 then msg_x = 1 end
    if msg_y < 2 then msg_y = 2 end
    gpu.set(msg_x, msg_y, msg)
    data._h = h
    data._w = w
    return
  end

  -- ------------------------------------------------------------------
  -- Content rows: lines displayed from row 2 through row h-2
  --   start_idx = #lines - h + 2 - offset   (clamped)
  --   end_idx   = #lines - offset           (clamped)
  -- ------------------------------------------------------------------
  local start_idx = #data.lines - h + 2 - data.offset
  if start_idx < 1 then start_idx = 1 end
  if start_idx > #data.lines then start_idx = #data.lines end

  local end_idx = #data.lines - data.offset
  if end_idx < 1 then end_idx = 1 end
  if end_idx > #data.lines then end_idx = #data.lines end

  local row = 2
  for i = start_idx, end_idx do
    if row >= h then break end -- safety; content stops at h-2, status on h-1
    local line = data.lines[i]
    if line then
      -- Colour-code by substring match (case-sensitive)
      if string.find(line, "FAILED", 1, true) or string.find(line, "ERROR", 1, true) then
        gpu.setForeground(0xFF0000)
      elseif string.find(line, "Phase", 1, true) then
        gpu.setForeground(0xFFFF00)
      elseif string.find(line, "dispatched", 1, true) then
        gpu.setForeground(0x00FF00)
      else
        gpu.setForeground(0xFFFFFF)
      end
      gpu.setBackground(0x000000)
      -- Truncate to w-2 characters
      gpu.set(1, row, string.sub(line, 1, w - 2))
    end
    row = row + 1
  end

  -- ------------------------------------------------------------------
  -- Row h-1: status bar  (right-aligned line count, left follow toggle)
  -- ------------------------------------------------------------------
  local status_row = h - 1
  if status_row < 2 then status_row = 2 end

  -- Follow toggle
  if data.follow then
    gpu.setForeground(0x00FFFF)
    gpu.setBackground(0x000000)
    gpu.set(1, status_row, "[Follow:ON]")
  else
    gpu.setForeground(0x808080)
    gpu.setBackground(0x000000)
    gpu.set(1, status_row, "[Follow:OFF]")
  end

  -- Line count, right-aligned
  gpu.setForeground(0x808080)
  gpu.setBackground(0x000000)
  local count_str = "Line " .. end_idx .. " of " .. #data.lines
  local count_x = w - #count_str + 1
  if count_x < 1 then count_x = 1 end
  gpu.set(count_x, status_row, count_str)

  -- Stash dimensions for handle_key
  data._h = h
  data._w = w
end

---------------------------------------------------------------------------
-- handle_key(code, data)
-- Key code dispatch.  Modifies data.offset / data.follow in place.
---------------------------------------------------------------------------
function module.handle_key(code, data)
  local h = data._h or 20

  if code == 200 then           -- Up arrow
    data.offset = data.offset + 1
  elseif code == 208 then       -- Down arrow
    data.offset = data.offset - 1
  elseif code == 201 then       -- Page Up
    data.offset = data.offset + 10
  elseif code == 209 then       -- Page Down
    data.offset = data.offset - 10
  elseif code == 199 then       -- Home
    data.offset = #data.lines
  elseif code == 207 then       -- End
    data.offset = 0
  elseif code == 57 then        -- Space
    data.follow = not data.follow
  else
    return                       -- ignored
  end

  -- Clamp offset: [0, max(0, #lines - h + 2)]
  local max_offset = math.max(0, #data.lines - h + 2)
  if data.offset < 0 then
    data.offset = 0
  elseif data.offset > max_offset then
    data.offset = max_offset
  end
end

return module
