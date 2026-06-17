--[[
  AutoOS — Transposer face probe (in-game wiring discovery)

  Run: loadfile("/home/subnet_broker/probe_transposer.lua")()
  One lane: loadfile("...")("machine_02")
]]

local LANE_ID = nil

local SIDE_NAMES = {
  [0] = "bottom", [1] = "top", [2] = "back",
  [3] = "front", [4] = "right", [5] = "left",
}

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("config")
local LaneSides = require("lane_sides")
local component = require("component")

local function is_circuit(stack, circuit_name)
  if type(stack) ~= "table" then return false end
  local name = stack.name or ""
  circuit_name = circuit_name or "integrated_circuit"
  return name == circuit_name or name:find(circuit_name, 1, true) ~= nil
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

local function probe_one(label, addr, machine, side_hints)
  print(string.format("  [%s] transposer %s", label, addr))
  local tp = proxy_transposer(addr)
  if not tp then
    print("    ERROR: proxy failed")
    return
  end
  for side = 0, 5 do
    local inv_ok, inv_size = pcall(tp.getInventorySize, side)
    inv_size = inv_ok and inv_size or 0
    local fluid_mb = fluid_mb_on_side(tp, side)
    local parts = {}
    if inv_size and inv_size > 0 then parts[#parts + 1] = inv_size .. " item slots" end
    if fluid_mb then parts[#parts + 1] = fluid_mb .. " mB fluid" end
    if #parts == 0 then parts[#parts + 1] = "empty" end
    local markers = side_hints[side]
    if type(markers) ~= "table" then markers = {} end
    local mark = #markers > 0 and ("  <<" .. table.concat(markers, ", ") .. ">>") or ""
    print(string.format("    side %d (%s): %s%s", side, SIDE_NAMES[side] or "?", table.concat(parts, ", "), mark))
  end
end

local function print_lane(machine)
  print(string.rep("-", 56))
  print(string.format("[Probe] %s", machine.id))
  print(string.format("  item  buffer=%s bus=%s return=%s",
    tostring(machine.side_buffer), tostring(machine.side_bus_b), tostring(machine.side_return or machine.side_buffer)))
  print(string.format("  fluid buffer=%s hatch=%s",
    tostring(LaneSides.fluid_buffer_side(machine)), tostring(LaneSides.fluid_hatch_side(machine))))

  local item_hints, fluid_hints = {}, {}
  item_hints[machine.side_buffer] = item_hints[machine.side_buffer] or {}
  item_hints[machine.side_buffer][#item_hints[machine.side_buffer] + 1] = "side_buffer"
  item_hints[machine.side_bus_b] = item_hints[machine.side_bus_b] or {}
  item_hints[machine.side_bus_b][#item_hints[machine.side_bus_b] + 1] = "side_bus_b"
  local ret = machine.side_return or machine.side_buffer
  item_hints[ret] = item_hints[ret] or {}
  item_hints[ret][#item_hints[ret] + 1] = "side_return"

  local fb = LaneSides.fluid_buffer_side(machine)
  fluid_hints[fb] = fluid_hints[fb] or {}
  fluid_hints[fb][#fluid_hints[fb] + 1] = "side_fluid_buffer"
  local fh = LaneSides.fluid_hatch_side(machine)
  fluid_hints[fh] = fluid_hints[fh] or {}
  fluid_hints[fh][#fluid_hints[fh] + 1] = "side_fluid_hatch"

  probe_one("item", LaneSides.item_transposer_address(machine), machine, item_hints)
  probe_one("fluid", LaneSides.fluid_transposer_address(machine), machine, fluid_hints)
end

local only = LANE_ID
local from_vararg = ...
if from_vararg and from_vararg ~= "" then only = from_vararg end
if arg and arg[1] and arg[1] ~= "" then only = arg[1] end

print("[AutoOS] Dual transposer probe — item + fluid per lane")
for _, m in ipairs(Config.machines) do
  if not only or m.id == only then print_lane(m) end
end
print(string.rep("-", 56))
