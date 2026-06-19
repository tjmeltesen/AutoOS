--[[
  AutoOS — Fluid probe (central buffer + lane buffer/hatch diagnostics)

  Usage:
    loadfile("/home/subnet_broker/probe_fluid.lua")()
    loadfile("/home/subnet_broker/probe_fluid.lua")("machine_01")
    loadfile("/home/subnet_broker/probe_fluid.lua")("machine_01", 1000, "--xfer")

  Notes:
    - Read-only by default (prints tank state only).
    - Optional "--xfer" runs one transferFluid(buffer -> hatch, amount) probe for lanes only.
]]

local BUILD = "2026-06-18"

local SIDE_NAMES = {
  [0] = "bottom", [1] = "top", [2] = "back",
  [3] = "front", [4] = "right", [5] = "left",
}

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

package.loaded.config = nil
package.loaded.lane_sides = nil
package.loaded.fluid_tanks = nil

local Config = require("config")
local LaneSides = require("lane_sides")
local component = require("component")
local FluidTanks = require("fluid_tanks")

local function proxy_adapter(addr)
  local ok, ad = pcall(component.proxy, addr, "adapter")
  if ok and ad then return ad end
  ok, ad = pcall(component.proxy, addr)
  return ok and ad or nil
end

local function proxy_transposer(addr)
  local ok, tp = pcall(component.proxy, addr, "transposer")
  if ok and tp then return tp end
  ok, tp = pcall(component.proxy, addr)
  return ok and tp or nil
end

local function fluid_rows(tp, side) return FluidTanks.fluid_rows(tp, side) end
local function tank_level(tp, side) return FluidTanks.tank_level(tp, side) end
local function tank_capacity(tp, side) return FluidTanks.tank_capacity(tp, side) end

local function print_side(tp, side, mark)
  local lvl = tank_level(tp, side)
  local cap = tank_capacity(tp, side)
  local cap_s = cap and tostring(cap) or "?"
  local line = string.format(
    "    side %d (%s): level=%s cap=%s%s",
    side, SIDE_NAMES[side] or "?", tostring(lvl), cap_s, mark or ""
  )
  print(line)
  local rows = fluid_rows(tp, side)
  if #rows == 0 then return end
  for _, row in ipairs(rows) do
    print(string.format("      tank[%d] %s : %s mB", row.idx, tostring(row.name), tostring(row.amount)))
  end
end

local function find_machine(machine_id)
  if not machine_id or machine_id == "" then return nil end
  for _, m in ipairs(Config.machines or {}) do
    if m.id == machine_id then return m end
  end
  return nil
end

local function bool_arg(v)
  if type(v) ~= "string" then return false end
  v = v:lower()
  return v == "--xfer" or v == "xfer" or v == "1" or v == "true"
end

local function run_lane_probe(machine, amount, do_xfer)
  local addr = LaneSides.fluid_transposer_address(machine)
  print(string.rep("-", 60))
  print(string.format("[FluidProbe] %s transposer=%s", tostring(machine.id), tostring(addr)))
  local tp = proxy_transposer(addr)
  if not tp then
    print("  ERROR: failed to proxy fluid transposer")
    return
  end

  local from_side = LaneSides.fluid_buffer_side(machine)
  local to_side = LaneSides.fluid_hatch_side(machine)
  print(string.format(
    "  configured pull(buffer)=%d (%s), push(hatch)=%d (%s)",
    from_side, SIDE_NAMES[from_side] or "?", to_side, SIDE_NAMES[to_side] or "?"
  ))

  for side = 0, 5 do
    local mark = ""
    if side == from_side then mark = "  <<side_fluid_buffer>>" end
    if side == to_side then
      mark = (mark ~= "" and (mark .. ", ") or "  <<") .. "side_fluid_hatch>>"
    end
    print_side(tp, side, mark)
  end

  if not do_xfer then return end
  if not tp.transferFluid then
    print("  xfer probe skipped: transposer has no transferFluid")
    return
  end
  local before_from = tank_level(tp, from_side)
  local before_to = tank_level(tp, to_side)
  local ok, moved = pcall(tp.transferFluid, from_side, to_side, amount)
  local after_from = tank_level(tp, from_side)
  local after_to = tank_level(tp, to_side)
  print(string.format(
    "  xfer probe amount=%d ok=%s moved=%s  from:%s->%s  to:%s->%s",
    amount, tostring(ok), tostring(moved),
    tostring(before_from), tostring(after_from),
    tostring(before_to), tostring(after_to)
  ))
end

local function print_central_side(dev, side, label)
  local mark = label and ("  <<" .. label .. ">>") or ""
  print_side(dev, side, mark)
end

local function run_central_probe()
  if Config.input_mode ~= "central" or type(Config.central) ~= "table" then return end
  local c = Config.central
  print(string.rep("-", 60))
  print("[FluidProbe] central buffer/adapters")

  if c.fluid_adapter_address and c.fluid_adapter_address ~= "" then
    print(string.format(
      "  central fluid_adapter=%s side=%s",
      tostring(c.fluid_adapter_address), tostring(c.fluid_adapter_side)
    ))
    local ad = proxy_adapter(c.fluid_adapter_address)
    if not ad then
      print("    ERROR: failed to proxy central fluid_adapter_address")
    elseif type(c.fluid_adapter_side) == "number" then
      print_central_side(ad, c.fluid_adapter_side, "central.fluid_adapter_side")
    else
      print("    NOTE: central.fluid_adapter_side is not set")
      for side = 0, 5 do print_side(ad, side, "") end
    end
  else
    print("  central fluid adapter not configured (central.fluid_adapter_address empty)")
  end

  if c.buffer_adapter_address and c.buffer_adapter_address ~= "" then
    print(string.format(
      "  central buffer_adapter=%s side=%s",
      tostring(c.buffer_adapter_address), tostring(c.buffer_adapter_side)
    ))
    local ad = proxy_adapter(c.buffer_adapter_address)
    if not ad then
      print("    ERROR: failed to proxy central buffer_adapter_address")
    elseif type(c.buffer_adapter_side) == "number" then
      print_central_side(ad, c.buffer_adapter_side, "central.buffer_adapter_side")
    else
      print("    NOTE: central.buffer_adapter_side is not set")
      for side = 0, 5 do print_side(ad, side, "") end
    end
  else
    print("  central buffer adapter not configured (central.buffer_adapter_address empty)")
  end
end

local machine_id, amount_arg, xfer_arg = ...
if (not machine_id or machine_id == "") and arg and arg[1] and arg[1] ~= "" then machine_id = arg[1] end
if (not amount_arg or amount_arg == "") and arg and arg[2] and arg[2] ~= "" then amount_arg = arg[2] end
if (not xfer_arg or xfer_arg == "") and arg and arg[3] and arg[3] ~= "" then xfer_arg = arg[3] end

local amount = tonumber(amount_arg) or 1000
local do_xfer = bool_arg(xfer_arg)

print(string.format("[AutoOS] Fluid probe %s (xfer=%s amount=%d)", BUILD, tostring(do_xfer), amount))
run_central_probe()

if machine_id and machine_id ~= "" then
  local m = find_machine(machine_id)
  if not m then
    print("ERROR: machine not found: " .. tostring(machine_id))
    os.exit(1)
  end
  run_lane_probe(m, amount, do_xfer)
else
  for _, m in ipairs(Config.machines or {}) do
    run_lane_probe(m, amount, do_xfer)
  end
end

print(string.rep("-", 60))
