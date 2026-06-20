-- broker_ui_logs.lua - Log viewer page for AutoOS Broker UI
-- Lua 5.2, OpenComputers. Self-sufficient: works with any data, even {}.

local LOG_PATH = "/var/log/autoos/lane_worker.log"

local module = { name = "Logs" }

function module.load_log_lines(path, max_lines)
  max_lines = max_lines or 500
  local f = io.open(path, "r")
  if not f then return {} end
  local all = {}
  for line in f:lines() do all[#all + 1] = line end
  f:close()
  local start = math.max(1, #all - max_lines + 1)
  local out = {}
  for i = start, #all do out[#out + 1] = all[i] end
  return out
end

function module.render(gpu, w, h, data)
  data = data or {}
  local path = data.path or LOG_PATH
  local lines = data.lines or module.load_log_lines(path, 200)
  local offset = data.offset or 0
  local follow = data.follow

  -- Ensure lines is always a table
  if type(lines) ~= "table" then lines = { tostring(lines) } end

  -- Clear
  gpu.setBackground(0x000000)
  gpu.fill(1, 1, w, h, " ")

  -- Header line
  gpu.setForeground(0x808080)
  local hdr = "--- Logs: " .. (path or "?")
  if #hdr > w then hdr = hdr:sub(1, w) end
  gpu.set(1, 1, hdr)

  -- No lines
  if #lines == 0 then
    gpu.setForeground(0x808080)
    local msg = "(no log data)"
    gpu.set(math.floor((w - #msg) / 2) + 1, math.floor(h / 2), msg)
    data._h = h; data._w = w; return
  end

  -- Follow mode pins to newest
  if follow then offset = 0; data.offset = 0 end

  -- Visible range
  local visible = h - 2
  if visible < 1 then visible = 1 end
  local end_idx = #lines - offset
  if end_idx < 1 then end_idx = #lines end
  if end_idx > #lines then end_idx = #lines end
  local start_idx = end_idx - visible + 1
  if start_idx < 1 then start_idx = 1 end

  -- Draw lines
  local row = 2
  for i = start_idx, end_idx do
    if row > h then break end
    local line = lines[i] or ""
    -- Color by content
    if line:find("FAILED", 1, true) or line:find("ERROR", 1, true) then
      gpu.setForeground(0xFF0000)
    elseif line:find("Phase", 1, true) then
      gpu.setForeground(0xFFFF00)
    elseif line:find("dispatched", 1, true) then
      gpu.setForeground(0x00FF00)
    else
      gpu.setForeground(0xFFFFFF)
    end
    gpu.set(1, row, line:sub(1, w))
    row = row + 1
  end

  -- Status bar on last line
  local sr = h
  if follow then
    gpu.setForeground(0x00FFFF)
    gpu.set(1, sr, "[Follow:ON]")
  else
    gpu.setForeground(0x808080)
    gpu.set(1, sr, "[Follow:OFF]")
  end
  gpu.setForeground(0x808080)
  local cnt = "L" .. end_idx .. "/" .. #lines
  gpu.set(w - #cnt, sr, cnt)

  data._h = h; data._w = w
end

function module.handle_key(code, data)
  data = data or {}
  data.lines = data.lines or {}
  local h = data._h or 20
  local max_off = math.max(0, #data.lines - h + 2)

  if code == 200 then data.offset = (data.offset or 0) + 1           -- Up
  elseif code == 208 then data.offset = (data.offset or 0) - 1       -- Down
  elseif code == 201 then data.offset = (data.offset or 0) + 10      -- PgUp
  elseif code == 209 then data.offset = (data.offset or 0) - 10      -- PgDn
  elseif code == 199 then data.offset = #data.lines                  -- Home
  elseif code == 207 then data.offset = 0                            -- End
  elseif code == 57 then data.follow = not data.follow               -- Space
  end

  if data.offset < 0 then data.offset = 0 end
  if data.offset > max_off then data.offset = max_off end
end

return module
