-- ui_utils.lua - Shared UI utility functions and color constants
-- Lua 5.2, OpenComputers. Stateless function table (no class, no constructor).
-- ponytail: shallow_copy and short_uuid added; add deep_copy if config mutation becomes a problem.

local U = {}

-- Safe GPU wrappers (pcall all calls — don't crash the UI on GPU errors)
function U.FG(g, c) if g and c then pcall(g.setForeground, c) end end
function U.GS(g, x, y, s) if g and x and y and s then pcall(g.set, x, y, tostring(s)) end end

-- pad_string_to_width(line, w): returns line padded to at least w chars (overwrites old GPU content)
function U.pad_string_to_width(s, w)
  return (s or "") .. string.rep(" ", math.max(0, w - #(s or "")))
end
-- Backward-compatible alias (internal codebase uses "pad")
U.pad = U.pad_string_to_width

-- format_uptime(sec): format duration (seconds to human-readable)
function U.format_uptime(sec)
  if not sec or sec < 0 then return "--" end
  if sec < 60 then return "<1m" end
  local d, h, m, s = math.floor(sec/86400), math.floor((sec%86400)/3600), math.floor((sec%3600)/60), math.floor(sec%60)
  if d > 0 then return string.format("%dd%dh", d, h) end
  if h > 0 then return string.format("%dh%dm", h, m) end
  if s > 0 then return string.format("%dm%ds", m, s) end
  return string.format("%dm", m)
end
-- Backward-compatible alias
U.fmtt = U.format_uptime

-- format_ago(now, t): format "ago" style time difference
function U.format_ago(now, t)
  if not now or not t then return "--" end
  local d = now - t; if d < 0 then return "--" end
  if d < 60 then return math.floor(d).."s" elseif d < 3600 then return math.floor(d/60).."m" else return math.floor(d/3600).."h" end
end
-- Backward-compatible alias
U.fmtag = U.format_ago

-- Colors (hex, supported on all OC GPU tiers >= 2)
U.G    = 0x00FF00
U.W    = 0xFFFFFF
U.Y    = 0xFFFF00
U.R    = 0xFF0000
U.GRAY = 0x808080
U.CYAN = 0x00FFFF

-- shallow_copy(t): shallow table clone (avoids shared-reference bugs in page data)
function U.shallow_copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

-- shorten_uuid(uuid): shorten a UUID string for compact display
function U.shorten_uuid(uuid)
  if type(uuid) ~= "string" then return tostring(uuid) end
  local short = uuid:gsub(":(%x%x%x%x%x%x%x%x)%-[%x%-]+", ":%1...")
  if #short > 45 then short = short:sub(1, 44) .. "." end
  return short
end

return U
