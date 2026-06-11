--[[
  AutoOS — one-shot GT machine diagnostic (run in-game)

  Dumps everything gt_machine reports so you can see what changes when you
  remove a block, cut power, etc. Paste the output when tuning fault detection.

  Usage (OpenComputers shell):
    lua /home/AutoOS/dump.lua
    lua /home/dump.lua
]]

local component = require("component")

if not component.isAvailable("gt_machine") then
  print("No gt_machine found. Connect adapter to GT controller.")
  return
end

local m = component.gt_machine

local function try(name, fn)
  local ok, result = pcall(fn)
  if ok then
    print(string.format("  %s = %s", name, tostring(result)))
  else
    print(string.format("  %s = (error: %s)", name, tostring(result)))
  end
end

print("=== AutoOS gt_machine dump ===")
try("getName", function() return m.getName() end)
try("isWorkAllowed", function() return m.isWorkAllowed() end)
try("isMachineActive", function() return m.isMachineActive() end)
try("hasWork", function() return m.hasWork() end)
try("getWorkProgress", function() return m.getWorkProgress() end)
try("getWorkMaxProgress", function() return m.getWorkMaxProgress() end)
try("getAverageElectricInput", function() return m.getAverageElectricInput() end)
try("getStoredEU", function() return m.getStoredEU() end)

print("  getSensorInformation():")
local ok, lines = pcall(function() return m.getSensorInformation() end)
if ok and type(lines) == "table" then
  for i, line in ipairs(lines) do
    print(string.format("    [%d] %s", i, line))
  end
  if #lines == 0 then
    print("    (empty table)")
  end
else
  print("    (error: " .. tostring(lines) .. ")")
end

print("=== end dump ===")
