--[[
  AutoOS — Transposer face probe (in-game wiring discovery)
  build: 2026-06-16c

  loadfile("/home/subnet_broker/probe_transposer.lua")()
  loadfile("/home/subnet_broker/find.lua")("probe")
]]

local PROBE_BUILD = "2026-06-16c"

local SIDE_NAMES = {
  [0] = "bottom", [1] = "top", [2] = "back",
  [3] = "front", [4] = "right", [5] = "left",
}

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

package.loaded.config = nil
package.loaded.lane_sides = nil

local Config = require("config")
local LaneSides = require("lane_sides")
local component = require("component")

local function add_hint(hints, side, label)
  if type(side) ~= "number" then return end
  local prev = hints[side]
  hints[side] = prev and (prev .. ", " .. label) or label
end

local function mark_for(side, hints)
  local text = hints[side]
  if not text or text == "" then return "" end
  return "  <<" .. text .. ">>"
end

local function fluid_mb_on_side(tp, side)
  if not tp.getTankLevel then return nil end
  local ok, lvl = pcall(tp.getTankLevel, side, 1)
  if ok and type(lvl) == "number" and lvl > 0 then return lvl end
  return nil
end

local function proxy_transposer(addr)
  local ok, tp = pcall(component.proxy, addr, "transposer")
  if ok and tp then return tp end
  ok, tp = pcall(component.proxy, addr)
  return ok and tp or nil
end

local function describe_side(tp, side, hints)
  local inv_ok, inv_size = pcall(tp.getInventorySize, side)
  inv_size = inv_ok and inv_size or 0
  local fluid_mb = fluid_mb_on_side(tp, side)
  local desc = {}
  if inv_size and inv_size > 0 then desc[#desc + 1] = inv_size .. " item slots" end
  if fluid_mb then desc[#desc + 1] = fluid_mb .. " mB fluid" end
  if #desc == 0 then desc[#desc + 1] = "empty" end
  return string.format("    side %d (%s): %s%s",
    side, SIDE_NAMES[side] or "?", table.concat(desc, ", "), mark_for(side, hints))
end

local function probe_one(label, addr, side_hints)
  print(string.format("  [%s] transposer %s", label, tostring(addr)))
  local tp = proxy_transposer(addr)
  if not tp then
    print("    ERROR: transposer proxy failed")
    return
  end
  for side = 0, 5 do
    print(describe_side(tp, side, side_hints))
  end
end

local function probe_central()
  if Config.input_mode ~= "central" or not Config.central then return end
  local c = Config.central
  print(string.rep("-", 56))
  print("[Probe] CENTRAL shared buffer (side_buffer=" .. tostring(c.side_buffer) .. ")")
  local item_hints, fluid_hints = {}, {}
  add_hint(item_hints, c.side_buffer, "central_chest")
  add_hint(fluid_hints, c.side_buffer, "central_tank")
  for _, m in ipairs(Config.machines) do
    add_hint(item_hints, m.central_item_side, m.id .. "_item_out")
    add_hint(fluid_hints, m.central_fluid_side, m.id .. "_fluid_out")
  end
  probe_one("central-item", c.item_transposer_address, item_hints)
  probe_one("central-fluid", c.fluid_transposer_address, fluid_hints)
end

local function print_lane(machine)
  print(string.rep("-", 56))
  print(string.format("[Probe] %s", machine.id))

  local item_hints, fluid_hints = {}, {}
  if Config.input_mode == "central" then
    add_hint(item_hints, machine.side_bus_b, "side_bus_b")
    add_hint(item_hints, machine.side_return or machine.side_buffer, "side_return")
    add_hint(fluid_hints, LaneSides.fluid_hatch_side(machine), "side_fluid_hatch")
    print(string.format("  central out item=%s fluid=%s",
      tostring(machine.central_item_side), tostring(machine.central_fluid_side)))
    print(string.format("  lane  bus=%s return=%s hatch=%s",
      tostring(machine.side_bus_b), tostring(machine.side_return or machine.side_buffer),
      tostring(LaneSides.fluid_hatch_side(machine))))
  else
    add_hint(item_hints, machine.side_buffer, "side_buffer")
    add_hint(item_hints, machine.side_bus_b, "side_bus_b")
    add_hint(item_hints, machine.side_return or machine.side_buffer, "side_return")
    add_hint(fluid_hints, LaneSides.fluid_buffer_side(machine), "side_fluid_buffer")
    add_hint(fluid_hints, LaneSides.fluid_hatch_side(machine), "side_fluid_hatch")
    print(string.format("  item  buffer=%s bus=%s return=%s",
      tostring(machine.side_buffer), tostring(machine.side_bus_b),
      tostring(machine.side_return or machine.side_buffer)))
    print(string.format("  fluid buffer=%s hatch=%s",
      tostring(LaneSides.fluid_buffer_side(machine)),
      tostring(LaneSides.fluid_hatch_side(machine))))
  end

  probe_one("item", LaneSides.item_transposer_address(machine), item_hints)
  probe_one("fluid", LaneSides.fluid_transposer_address(machine), fluid_hints)
end

local only = ...
if (not only or only == "") and arg and arg[1] and arg[1] ~= "" then only = arg[1] end

print("[AutoOS] Transposer probe " .. PROBE_BUILD .. " (input_mode=" .. tostring(Config.input_mode) .. ")")
probe_central()
for _, m in ipairs(Config.machines) do
  if not only or only == "" or m.id == only then print_lane(m) end
end
print(string.rep("-", 56))
