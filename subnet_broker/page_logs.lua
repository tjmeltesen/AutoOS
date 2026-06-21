-- page_logs.lua - Log viewer page: scrollable log file with follow mode and color coding
-- Lua 5.2, OpenComputers. Inherits from BasePage.
-- ponytail: follow-mode defaults to true; add search/filter when users ask.

local BasePage = require("class_base_page")
local U = require("ui_utils")

local LogsPage = setmetatable({}, {__index = BasePage})
LogsPage.__index = LogsPage
LogsPage.page_id = "logs"

function LogsPage.new(deps)
  local o = BasePage.new(deps)
  setmetatable(o, LogsPage)
  o._offset = 0
  o._follow = true
  return o
end

function LogsPage:on_mount()
  self._offset = 0
  self._follow = true
end

function LogsPage:set_data(t)
  if type(t) ~= "table" then return end
  for k, v in pairs(t) do
    self.data[k] = v
  end
  -- follow mode: always reset offset to show latest
  if self._follow then
    self._offset = 0
    self.data.offset = 0
  end
end

function LogsPage:handle_input(event)
  local data = self.data
  local lines = data.lines; if type(lines) ~= "table" then lines = {} end
  local hh = self._h or 20
  local mx = math.max(0, #lines - hh + 2)

  if event.code == 200 then       -- Up
    self._offset = (self._offset or 0) + 1
  elseif event.code == 208 then   -- Down
    self._offset = (self._offset or 0) - 1
  elseif event.code == 201 then   -- PageUp
    self._offset = (self._offset or 0) + 10
  elseif event.code == 209 then   -- PageDown
    self._offset = (self._offset or 0) - 10
  elseif event.code == 199 then   -- Home: jump to end
    self._offset = #lines
  elseif event.code == 207 then   -- End: jump to start
    self._offset = 0
  elseif event.code == 57 then    -- Space: toggle follow
    self._follow = not self._follow
  else
    return false
  end

  if self._offset < 0 then self._offset = 0
  elseif self._offset > mx then self._offset = mx end
  data.offset = self._offset
  data.follow = self._follow
  return true
end

function LogsPage:render()
  local gpu = self.deps.gpu; if not gpu then return end
  local w, h = self._w, self._h
  local data = self.data
  local path = data.path or "/home/subnet_broker/lane_worker.log"
  local lines = data.lines; if type(lines) ~= "table" then lines = {} end
  local offset = self._offset or 0
  local follow = self._follow

  -- Auto-follow: reset offset to show tail
  if follow then offset = 0; self._offset = 0; data.offset = 0 end

  -- Header
  U.FG(gpu, U.GRAY)
  U.GS(gpu, 1, 1, U.pad(("--- Logs: %s"):format(path or "?"), w))

  if #lines == 0 then
    U.FG(gpu, U.GRAY)
    U.GS(gpu, 1, math.floor(h / 2), U.pad("(no log data)", w))
    return
  end

  local vis = h - 2; if vis < 1 then vis = 1 end
  local ei = #lines - offset; if ei < 1 then ei = #lines elseif ei > #lines then ei = #lines end
  local si = ei - vis + 1; if si < 1 then si = 1 end

  for i = si, ei do
    local lr = 2 + i - si; if lr > h then break end
    local line = lines[i] or ""
    local lc = U.W
    if line:find("FAILED", 1, true) or line:find("ERROR", 1, true) then
      lc = U.R
    elseif line:find("Phase", 1, true) then
      lc = U.Y
    elseif line:find("dispatched", 1, true) then
      lc = U.G
    end
    U.FG(gpu, lc)
    U.GS(gpu, 1, lr, U.pad(line, w))
  end

  -- Footer: follow indicator + line counter
  U.FG(gpu, follow and U.CYAN or U.GRAY)
  U.GS(gpu, 1, h, U.pad(follow and "[Follow:ON]" or "[Follow:OFF]", w))
  U.FG(gpu, U.GRAY)
  local cnt = ("L%d/%d"):format(ei, #lines)
  U.GS(gpu, w - #cnt + 1, h, cnt)
end

return LogsPage
