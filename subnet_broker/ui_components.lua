-- ui_components.lua - Shared visual component drawing functions
-- Lua 5.2, OpenComputers. Stateless function table.
-- All functions take deps as first argument (contains gpu + theme).
-- Colors pulled strictly from deps.theme — no hardcoded hex values.
-- ponytail: draw_scrollable_list skipped — dashboard needs color batching, add when second scrollable page exists.

local U = require("ui_utils")

local C = {}

-- draw_header(deps, title, status_line, w)
-- Draws rows 1-2 and a separator. Returns the next available row.
function C.draw_header(deps, title, status_line, w)
  local gpu = deps.gpu
  local theme = deps.theme or {}
  U.FG(gpu, theme.text_muted)
  U.GS(gpu, 1, 1, U.pad(title:sub(1, w), w))
  if status_line then
    U.GS(gpu, 1, 2, U.pad(status_line:sub(1, w), w))
  end
  local sep_row = status_line and 3 or 2
  U.GS(gpu, 1, sep_row, string.rep("-", w))
  return sep_row + 1
end

-- draw_footer_nav(deps, footer_text, w, h)
-- Draws the navigation/help bar on the bottom row.
function C.draw_footer_nav(deps, footer_text, w, h)
  local gpu = deps.gpu
  local theme = deps.theme or {}
  U.FG(gpu, theme.text_muted)
  U.GS(gpu, 1, h, U.pad(footer_text:sub(1, w), w))
end

-- draw_text_input(deps, x, y, width, current_text, is_active)
-- Draws a text input with optional blinking cursor underscore.
function C.draw_text_input(deps, x, y, width, current_text, is_active)
  local gpu = deps.gpu
  local theme = deps.theme or {}
  local display = current_text or ""
  if is_active then display = display .. "_" end
  U.FG(gpu, is_active and theme.highlight or theme.text_primary)
  U.GS(gpu, x, y, U.pad(display, width))
end

-- draw_config_label(deps, x, y, width, label, value, is_focused, is_locked)
-- Draws a config field label/value pair in one row.
function C.draw_config_label(deps, x, y, width, label, value, is_focused, is_locked)
  local gpu = deps.gpu
  local theme = deps.theme or {}
  local lb = label
  if #lb > 20 then lb = lb:sub(1, 19) .. "." end
  local fc
  if is_locked then
    fc = theme.dim_text
  elseif is_focused then
    fc = theme.highlight
  else
    fc = theme.text_primary
  end
  U.FG(gpu, fc)
  U.GS(gpu, x, y, U.pad(string.format(" %-21s %s", lb, tostring(value or "")), width))
end

return C
