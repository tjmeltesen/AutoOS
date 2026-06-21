-- ui_components.lua - Shared visual component drawing functions
-- Lua 5.2, OpenComputers. Stateless function table.
-- All functions take gpu as first argument; caller owns the GPU handle.
-- ponytail: draw_scrollable_list skipped — dashboard needs color batching, add when second scrollable page exists.

local U = require("ui_utils")

local C = {}

-- draw_header(gpu, title, status_line, w)
-- Draws rows 1-2 and a separator. Returns the next available row.
function C.draw_header(gpu, title, status_line, w)
  U.FG(gpu, U.GRAY)
  U.GS(gpu, 1, 1, U.pad(title:sub(1, w), w))
  if status_line then
    U.GS(gpu, 1, 2, U.pad(status_line:sub(1, w), w))
  end
  local sep_row = status_line and 3 or 2
  U.GS(gpu, 1, sep_row, string.rep("-", w))
  return sep_row + 1
end

-- draw_footer_nav(gpu, footer_text, w, h)
-- Draws the navigation/help bar on the bottom row.
function C.draw_footer_nav(gpu, footer_text, w, h)
  U.FG(gpu, U.GRAY)
  U.GS(gpu, 1, h, U.pad(footer_text:sub(1, w), w))
end

-- draw_text_input(gpu, x, y, width, current_text, is_active)
-- Draws a text input with optional blinking cursor underscore.
function C.draw_text_input(gpu, x, y, width, current_text, is_active)
  local display = current_text or ""
  if is_active then display = display .. "_" end
  U.FG(gpu, is_active and U.CYAN or U.W)
  U.GS(gpu, x, y, U.pad(display, width))
end

-- draw_config_label(gpu, x, y, width, label, value, is_focused, is_locked)
-- Draws a config field label/value pair in one row.
function C.draw_config_label(gpu, x, y, width, label, value, is_focused, is_locked)
  local lb = label
  if #lb > 20 then lb = lb:sub(1, 19) .. "." end
  local fc
  if is_locked then
    fc = 0x404040
  elseif is_focused then
    fc = U.CYAN
  else
    fc = U.W
  end
  U.FG(gpu, fc)
  U.GS(gpu, x, y, U.pad(string.format(" %-21s %s", lb, tostring(value or "")), width))
end

return C
