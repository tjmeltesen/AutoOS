--[[
  AutoOS — Standalone Config Editor
  Edit /home/subnet_broker/config.lua with split-pane UI.
  No broker context needed.  Ctrl+S writes to disk.
  Run: lua broker_config.lua
]]

local BROKER_BUILD = "2026-06-21-config-standalone"

-- This script lives in /home/.  Dependencies are in /home/subnet_broker/.
local sep = package.config:sub(1, 1)
package.path = "/home/subnet_broker" .. sep .. "?.lua;" .. package.path

---------------------------------------------------------------------------
-- GPU detection
---------------------------------------------------------------------------
local function detect_gpu()
  local ok_comp, component = pcall(require, "component")
  if not ok_comp or not component then return nil, nil end
  local ok_gpu = pcall(function() return component.isAvailable("gpu") end)
  if not ok_gpu then return nil, nil end
  local gpu = component.gpu
  local screen_addr = nil
  if pcall(function() return component.isAvailable("screen") end) then
    for addr in component.list("screen") do screen_addr = addr; break end
  end
  return gpu, screen_addr
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
local gpu, screen_addr = detect_gpu()
if not gpu then
  print("[Config] no GPU — headless mode, exiting")
  return
end

local theme = {
  bg_default     = 0x000000,  bg_panel       = 0x1A1A1A,
  text_primary   = 0xFFFFFF,  text_muted     = 0x888888,
  accent_success = 0x00FF00,  accent_error   = 0xFF0000,
  accent_warning = 0xFFA500,  highlight      = 0x0055FF,
  dim_text       = 0x404040,
}

local now_fn = os.clock
pcall(function() now_fn = require("computer").uptime end)

local PageConfig = require("page_config")
local page = PageConfig.new({ gpu = gpu, screen_addr = screen_addr, theme = theme, now_fn = now_fn })

---------------------------------------------------------------------------
-- Event loop
---------------------------------------------------------------------------
local event = require("event")
local ok_kb, kb = pcall(require, "keyboard")
if screen_addr then pcall(gpu.bind, screen_addr) end
local mw, mh = 80, 25
pcall(function()
  local ok, w, h = pcall(gpu.getResolution)
  if ok and w and h then mw, mh = w, h end
end)
pcall(gpu.setResolution, mw, mh)

if page.on_mount then pcall(page.on_mount, page) end
page._w, page._h = mw, mh - 1

local running, last_render = true, 0
while running do
  local ev = { event.pull(0.05) }
  if ev[1] == "key_down" then
    local code, char = ev[4], ev[3]
    -- Q quits
    if code == 16 then
      running = false
    -- Ctrl+S: let page handle directly (no router gate needed)
    elseif code == 31 and kb and kb.isControlDown() then
      page:handle_input({ code = code, char = char })
      last_render = 0
    elseif page.handle_input then
      page:handle_input({ code = code, char = char })
      if page.redraw_field then page:redraw_field(page._ff) end
    end
  end
  local now = now_fn()
  if now - last_render >= 0.5 then
    pcall(page.render, page)
    last_render = now
  end
end

pcall(gpu.fill, 1, 1, mw, mh, " ")
pcall(gpu.setForeground, 0xFFFFFF)
pcall(gpu.set, 1, 1, "Config editor closed.")
