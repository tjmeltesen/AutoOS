--[[
  AutoOS — Pull-through test: central buffer → dual IF → transposer → hatch

  Usage (in-game):
    loadfile("/home/subnet_broker/pull_through.lua")()
    loadfile("/home/subnet_broker/pull_through.lua")("machine_01")
    loadfile("/home/subnet_broker/pull_through.lua")("machine_01", "Hydrogen")

  Verifies:
    1. ME interface can configure fluids on the transposer pull side
    2. AE2 delivers them to the dual IF
    3. Transposer sees fluid on the pull side (getFluidInTank / getTankLevel)
    4. transferFluid moves it from pull side → hatch
]]

local BUILD = "2026-06-19"

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
local FluidTanks = require("fluid_tanks")
local component = require("component")

local function proxy(addr, ptype)
  if not addr or addr == "" then return nil end
  local ok, p = pcall(component.proxy, addr, ptype)
  if ok and p then return p end
  ok, p = pcall(component.proxy, addr)
  return ok and p or nil
end

local function find_machine(id)
  for _, m in ipairs(Config.machines or {}) do
    if m.id == id then return m end
  end
end

local function show_tanks(tp, side, label)
  label = label or ("side " .. tostring(side) .. " (" .. (SIDE_NAMES[side] or "?") .. ")")
  local lvl = FluidTanks.tank_level(tp, side)
  local cap = FluidTanks.tank_capacity(tp, side)
  print(string.format("  %s: level=%s cap=%s", label, tostring(lvl), tostring(cap or "?")))
  for _, row in ipairs(FluidTanks.fluid_rows(tp, side)) do
    print(string.format("    tank[%d] %s : %s mB", row.idx, tostring(row.name), tostring(row.amount)))
  end
end

local function run(args)
  local machine_id = args[1] or "machine_01"
  local filter_fluid = args[2]  -- optional, just for logging

  print(string.format("=== pull_through %s | machine=%s ===", BUILD, machine_id))

  local m = find_machine(machine_id)
  if not m then
    print("ERROR: machine '" .. machine_id .. "' not found in config")
    return
  end

  -- Resolve proxies
  local iface = proxy(m.interface_address, "me_interface")
  local item_tp = proxy(LaneSides.item_transposer_address(m), "transposer")
  local fluid_tp = proxy(LaneSides.fluid_transposer_address(m), "transposer")

  print(string.format("interface=%s", m.interface_address or "(none)"))
  print(string.format("item_tp   =%s (%s)", LaneSides.item_transposer_address(m),
    item_tp and "OK" or "MISSING"))
  print(string.format("fluid_tp  =%s (%s)", LaneSides.fluid_transposer_address(m),
    fluid_tp and "OK" or "MISSING"))

  -- Sides
  local item_pull  = LaneSides.central_item_pull_side(m)
  local fluid_pull = LaneSides.central_fluid_pull_side(m)
  local bus_side   = LaneSides.bus_side(m)
  local hatch_side = LaneSides.fluid_hatch_side(m)

  print(string.format("item_pull_side=%d  fluid_pull_side=%d  bus_side=%d  hatch_side=%d",
    item_pull, fluid_pull, bus_side, hatch_side))

  -- ── 1. Show current state ──
  print("\n── Before (fluid transposer) ──")
  if fluid_tp then
    for _, side in ipairs({fluid_pull, hatch_side}) do
      show_tanks(fluid_tp, side)
    end
  else
    print("  (no fluid transposer)")
  end

  -- ── 2. Try to stock a fluid via the interface ──
  if not iface then
    print("\nERROR: no ME interface proxy — cannot stock")
    return
  end
  if not iface.setFluidInterfaceConfiguration then
    print("\nERROR: ME interface missing setFluidInterfaceConfiguration")
    return
  end

  -- Find any fluid already configured so we can test with it
  print("\n── Existing fluid configs ──")
  local configured_side = nil
  for side = 0, 5 do
    local ok, cfg = pcall(iface.getFluidInterfaceConfiguration, side)
    if ok and cfg and cfg ~= false then
      print(string.format("  side %d: address=%s slot=%s",
        side, tostring(cfg.address or cfg[1] or "?"), tostring(cfg.slot or cfg[2] or "?")))
      if not configured_side then configured_side = side end
    end
  end

  if not configured_side then
    print("  (no existing fluid configs — use in-game interface GUI to set one up first)")
    print("   Or call: iface.setFluidInterfaceConfiguration(pull_side, db_addr, db_slot)")
  end

  -- ── 3. Poll delivery ──
  print(string.format("\n── Polling delivery on pull side %d ──", fluid_pull))
  local deadline = component.computer.uptime() + 10
  local delivered = false
  while component.computer.uptime() < deadline do
    if fluid_tp and FluidTanks.tank_level(fluid_tp, fluid_pull) > 0 then
      delivered = true
      break
    end
    os.sleep(0.2)
  end

  if delivered then
    print("  DELIVERED — fluid visible on pull side:")
    show_tanks(fluid_tp, fluid_pull)
  else
    print("  NOT DELIVERED after 10s timeout")
    if fluid_tp then
      show_tanks(fluid_tp, fluid_pull)
    end
  end

  -- ── 4. Transfer pull → hatch ──
  if delivered and fluid_tp then
    print(string.format("\n── Transfer pull(%d) → hatch(%d) ──", fluid_pull, hatch_side))
    local before_hatch = FluidTanks.tank_level(fluid_tp, hatch_side)
    local before_pull  = FluidTanks.tank_level(fluid_tp, fluid_pull)

    local ok, moved = pcall(fluid_tp.transferFluid, fluid_pull, hatch_side, before_pull)
    if not ok then
      print(string.format("  FAILED: %s", tostring(moved)))
    elseif not moved or moved == 0 then
      print(string.format("  moved=0 (transfer rejected or hatch full)"))
    else
      print(string.format("  moved=%s mB", tostring(moved)))
    end

    print("\n── After transfer ──")
    show_tanks(fluid_tp, fluid_pull, "pull side")
    show_tanks(fluid_tp, hatch_side, "hatch side")
    local after_hatch = FluidTanks.tank_level(fluid_tp, hatch_side)
    print(string.format("  hatch delta: %s → %s (+%s)",
      tostring(before_hatch), tostring(after_hatch),
      tostring((after_hatch or 0) - (before_hatch or 0))))
  end

  print("\n=== done ===")
end

local ok, err = pcall(run, {...})
if not ok then
  print("pull_through crashed: " .. tostring(err))
end
