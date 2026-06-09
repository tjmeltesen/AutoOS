--[[
  AutoOS — one-shot ME network diagnostic (run in-game)

  Use when autocraft does not fire: discovers exact fluid/item labels and
  whether getCraftables finds your pattern. Paste output when tuning start.lua.

  Usage:
    lua /home/AutoOS/me_dump.lua
    lua /home/AutoOS/me_dump.lua Oxygen
]]

local component = require("component")

local needle = (arg and arg[1]) or "oxygen"
local lower_needle = needle:lower()

local function me_proxy()
  if component.isAvailable("me_interface") then
    return component.me_interface, "me_interface"
  end
  if component.isAvailable("me_controller") then
    return component.me_controller, "me_controller"
  end
  return nil, nil
end

local me, me_type = me_proxy()
if not me then
  print("No me_interface or me_controller found. Connect adapter to ME block.")
  return
end

print("=== AutoOS ME dump ===")
print("  proxy: " .. me_type)
print("  search: " .. needle)

local function matches(label)
  return type(label) == "string" and label:lower():find(lower_needle, 1, true)
end

print("\n-- Fluids in network (getFluidsInNetwork) --")
if me.getFluidsInNetwork then
  local any = false
  for _, f in ipairs(me.getFluidsInNetwork() or {}) do
    if matches(f.label) then
      any = true
      print(string.format("  fluid  label=%q  amount=%s mB", f.label, tostring(f.amount)))
    end
  end
  if not any then print("  (no matching fluids)") end
else
  print("  (getFluidsInNetwork not available)")
end

print("\n-- Items in network (filtered getItemsInNetwork) --")
if me.getItemsInNetwork then
  local items = me.getItemsInNetwork({ label = needle })
  if type(items) == "table" and #items > 0 then
    for _, s in ipairs(items) do
      print(string.format("  item   label=%q  size=%s", s.label, tostring(s.size)))
    end
  else
    -- scan discretized fluid drops
    local any = false
    for _, s in ipairs(me.getItemsInNetwork() or {}) do
      if matches(s.label) then
        any = true
        print(string.format("  item   label=%q  size=%s", s.label, tostring(s.size)))
      end
    end
    if not any then print("  (no matching items)") end
  end
end

print("\n-- Craftables (getCraftables) --")
if me.getCraftables then
  local labels_to_try = { needle, "drop of " .. needle }
  for _, lab in ipairs(labels_to_try) do
    local crafts = me.getCraftables({ label = lab })
    local n = type(crafts) == "table" and #crafts or 0
    print(string.format("  filter label=%q -> %d craftable(s)", lab, n))
  end
else
  print("  (getCraftables not available on this proxy)")
end

print("\n-- Suggested start.lua fields --")
print('  label = "<exact fluid label from above>"')
print('  kind = "fluid"   -- if listed under fluids')
print('  mode = "craft"')
print('  low / high = mB thresholds (e.g. low=4000 high=16000 for 4b/16b)')
print("=== end dump ===")
