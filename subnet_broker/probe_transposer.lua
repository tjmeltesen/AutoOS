--[[
  AutoOS — Transposer + central adapter probe (in-game wiring discovery)
  build: 2026-06-17

  loadfile("/home/subnet_broker/probe_transposer.lua")()
  loadfile("/home/subnet_broker/find.lua")("probe")
]]

local PROBE_BUILD = "2026-06-17"

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

local function proxy_adapter(addr)
  local ok, ad = pcall(component.proxy, addr, "adapter")
  if ok and ad then return ad end
  ok, ad = pcall(component.proxy, addr)
  return ok and ad or nil
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

local function describe_adapter_side(ad, side, label)
  local inv_ok, inv_size = pcall(ad.getInventorySize, side)
  inv_size = inv_ok and inv_size or 0
  local parts = {}
  if inv_size and inv_size > 0 then
    parts[#parts + 1] = inv_size .. " item slots"
    for slot = 1, math.min(inv_size, 9) do
      local ok, st = pcall(ad.getStackInSlot, side, slot)
      if ok and type(st) == "table" and (st.size or 0) > 0 then
        parts[#parts + 1] = string.format("slot%d=%dx%s", slot, st.size or 0, tostring(st.name))
      end
    end
  end
  local fluid_mb = fluid_mb_on_side(ad, side)
  if fluid_mb then parts[#parts + 1] = fluid_mb .. " mB fluid" end
  if #parts == 0 then parts[#parts + 1] = "empty" end
  return string.format("    side %d (%s) [%s]: %s",
    side, SIDE_NAMES[side] or "?", label, table.concat(parts, ", "))
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

local function probe_central_adapters()
  if Config.input_mode ~= "central" or not Config.central then return end
  local c = Config.central
  print(string.rep("-", 56))
  print("[Probe] CENTRAL buffer adapters (storage bus — no central transposers)")
  print(string.format("  stabilize_s=%s", tostring(c.stabilize_s or 3.0)))
  if c.buffer_adapter_address and c.buffer_adapter_address ~= "" then
    print(string.format("  item chest adapter %s side=%s",
      tostring(c.buffer_adapter_address), tostring(c.buffer_adapter_side)))
    local ad = proxy_adapter(c.buffer_adapter_address)
    if ad and type(c.buffer_adapter_side) == "number" then
      print(describe_adapter_side(ad, c.buffer_adapter_side, "item_chest"))
    else
      print("    ERROR: item adapter proxy failed")
    end
  end
  if c.fluid_adapter_address and c.fluid_adapter_address ~= "" then
    print(string.format("  fluid tank adapter %s (optional)",
      tostring(c.fluid_adapter_address)))
    local ad = proxy_adapter(c.fluid_adapter_address)
    if ad and type(c.fluid_adapter_side) == "number" then
      print(describe_adapter_side(ad, c.fluid_adapter_side, "fluid_tank"))
    end
  end
end

local function print_lane(machine)
  print(string.rep("-", 56))
  print(string.format("[Probe] %s", machine.id))

  local item_hints, fluid_hints = {}, {}
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

  probe_one("item", LaneSides.item_transposer_address(machine), item_hints)
  probe_one("fluid", LaneSides.fluid_transposer_address(machine), fluid_hints)
end

local only = ...
if (not only or only == "") and arg and arg[1] and arg[1] ~= "" then only = arg[1] end

print("[AutoOS] Transposer probe " .. PROBE_BUILD .. " (input_mode=" .. tostring(Config.input_mode) .. ")")
probe_central_adapters()
for _, m in ipairs(Config.machines) do
  if not only or only == "" or m.id == only then print_lane(m) end
end
print(string.rep("-", 56))
