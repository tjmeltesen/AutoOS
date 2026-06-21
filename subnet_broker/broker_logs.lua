--[[
  AutoOS — Standalone Log Viewer
  Reads /home/subnet_broker/lane_worker.log with scroll + follow mode.
  No broker context needed.
  Run: lua broker_logs.lua
]]

local LOG_PATH = "/home/subnet_broker/lane_worker.log"

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
  print("[Logs] no GPU — headless mode, exiting")
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

local LogsPage = require("page_logs")
local page = LogsPage.new({ gpu = gpu, screen_addr = screen_addr, theme = theme, now_fn = now_fn })

local function read_log()
  local lines = {}
  local f = io.open(LOG_PATH, "r")
  if f then
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
  end
  return lines
end

---------------------------------------------------------------------------
-- Event loop
---------------------------------------------------------------------------
local event = require("event")
if screen_addr then pcall(gpu.bind, screen_addr) end
local mw, mh = 80, 25
pcall(function()
  local ok, w, h = pcall(gpu.getResolution)
  if ok and w and h then mw, mh = w, h end
end)
pcall(gpu.setResolution, mw, mh)

if page.on_mount then pcall(page.on_mount, page) end
page._w, page._h = mw, mh - 1

-- Initial load
page:set_data({ lines = read_log(), path = LOG_PATH, follow = true, offset = 0 })

local running, last_load, last_render = true, 0, 0
while running do
  local ev = { event.pull(0.05) }
  if ev[1] == "key_down" then
    local code, char = ev[4], ev[3]
    if code == 16 then  -- Q quits
      running = false
    elseif page.handle_input then
      page:handle_input({ code = code, char = char })
    end
  end
  local now = now_fn()
  -- Re-read log every 1s
  if now - last_load >= 1.0 then
    local lines = read_log()
    page:set_data({ lines = lines, path = LOG_PATH, follow = page._follow, offset = page._offset })
    last_load = now
  end
  -- Render at 2fps
  if now - last_render >= 0.5 then
    pcall(page.render, page)
    last_render = now
  end
end

pcall(gpu.fill, 1, 1, mw, mh, " ")
pcall(gpu.setForeground, 0xFFFFFF)
pcall(gpu.set, 1, 1, "Log viewer closed.")
