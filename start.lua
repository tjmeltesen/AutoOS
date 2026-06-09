--[[
  AutoOS — in-game boot script (place at /home/start.lua)

  Sets package.path for /home/AutoOS/ layout, then starts the kernel.
  wget from: https://raw.githubusercontent.com/tjmeltesen/AutoOS/main/start.lua
]]

package.path = "/home/AutoOS/?.lua;/home/AutoOS/modules/?.lua;" .. package.path

local component = require("component")
local computer = require("computer")
local event = require("event")
local Kernel = require("main")

if not component.isAvailable("gt_machine") then
  print("AutoOS: no gt_machine found. Connect adapter to GT controller.")
  return
end

-- Phase 2 (optional): bind an ME proxy so the process-control hysteresis loop
-- can read inventory. Without a proxy + product config below, AutoOS runs the
-- Phase 1 maintenance safeguard only.
local me = nil
if component.isAvailable("me_interface") then
  me = component.me_interface
elseif component.isAvailable("me_controller") then
  me = component.me_controller
end

-- Optional read-only status monitor: bind the GPU to a screen when both are
-- present. Purely informational — it never controls the machine. Leave a
-- screen + GPU connected to watch live state while validating Phase 2.
local gpu, screen = nil, nil
if component.isAvailable("gpu") and component.isAvailable("screen") then
  gpu = component.gpu
  screen = component.screen.address
end

print("=== Starting AutoOS ===")
Kernel.new({
  machine = component.gt_machine,
  computer = computer,
  event = event,
  verbose = false, -- silent unless fault shutdown (recommended in-game)
  -- monitor = true,  -- uncomment to also log when work_allowed/active/sensors change

  -- Phase 2 hysteresis leveling. Enabled only when `me` is non-nil. Edit the
  -- label/thresholds to match the product this machine refills:
  --   low  : enter ACTIVE when stock drops below this
  --   high : leave ACTIVE once stock climbs above this (deadband prevents flapping)
  --   kind : "item" (getItemsInNetwork filter) or "fluid" (getFluidsInNetwork)
  --   mode : "craft" = ME autocraft only (needs AE recipe for label)
  --          "machine" = gt_machine on/off only
  --          "both" = machine on + ME craft request while refilling
  me = me,
  process_control = me and {
    label = "Soldering Alloy",
    low = 64000,
    high = 142800,
    kind = "item",
    mode = "craft",
  } or nil,

  -- Read-only status panel (no control). Omit gpu/screen to run headless.
  gpu = gpu,
  screen = screen,
}):run()
