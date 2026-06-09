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

print("=== Starting AutoOS ===")
Kernel.new({
  machine = component.gt_machine,
  computer = computer,
  event = event,
  verbose = false, -- silent unless fault shutdown (recommended in-game)
  -- monitor = true,  -- uncomment to also log when work_allowed/active/sensors change
}):run()
