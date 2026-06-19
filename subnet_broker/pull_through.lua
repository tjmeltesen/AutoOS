--[[
  AutoOS — Pull-through test: replicates lane_worker stock→wait→transfer
  Usage:
    loadfile("/home/subnet_broker/pull_through.lua")()
    loadfile("/home/subnet_broker/pull_through.lua")("machine_01")
]]

local BUILD = "2026-06-19"
local VERBOSE = true

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

package.loaded.config = nil
package.loaded.lane_sides = nil
package.loaded.fluid_tanks = nil

local Config       = require("config")
local LaneSides    = require("lane_sides")
local FluidTanks   = require("fluid_tanks")
local component    = require("component")
local computer     = require("computer")

-- ── probe helpers ──────────────────────────────────────────────────────────

local LOG_FILE = nil

local function log(fmt, ...)
  local msg = string.format("[pull_through] " .. fmt, ...)
  print(msg)
  if LOG_FILE then
    LOG_FILE:write(msg .. "\n")
    LOG_FILE:flush()
  end
end

local function log_open(filename)
  LOG_FILE = io.open("/home/subnet_broker/" .. filename, "w")
  if LOG_FILE then
    log("log opened: %s", filename)
  else
    print("[pull_through] WARN: cannot open " .. tostring(filename))
  end
end

local function log_close()
  if LOG_FILE then
    LOG_FILE:close()
    LOG_FILE = nil
  end
end

local function dump_tanks(tp, side, label)
  if not tp then log("%s: no transposer", label or "?"); return end
  local lvl = FluidTanks.tank_level(tp, side)
  local cap = FluidTanks.tank_capacity(tp, side)
  log("%s (side %d): level=%s cap=%s", label or "?", side, tostring(lvl), tostring(cap or "?"))
  for _, row in ipairs(FluidTanks.non_empty_tanks(tp, side)) do
    log("  tank[%d] %s : %s mB", row.idx, tostring(row.name), tostring(row.amount))
  end
end

-- ── component proxy (matching registry pattern) ────────────────────────────

local function proxy(addr, ptype)
  if not addr or addr == "" then return nil, "empty address" end
  local ok, p = pcall(component.proxy, addr, ptype)
  if ok and p then return p end
  ok, p = pcall(component.proxy, addr)
  if ok and p then return p end
  return nil, "proxy failed"
end

-- ── replicate lane_worker's stock_fluid_slot ───────────────────────────────

local function stock_fluid_slot(iface, side, db_address, db_slot)
  if not db_address or db_address == "" then
    return false, "empty db_address"
  end
  if type(db_slot) ~= "number" then
    return false, "db_slot not a number: " .. tostring(db_slot)
  end
  if not iface or not iface.setFluidInterfaceConfiguration then
    return false, "no setFluidInterfaceConfiguration"
  end
  local ok, err = pcall(iface.setFluidInterfaceConfiguration, side, db_address, db_slot)
  if not ok then return false, tostring(err) end
  if err == false then return false, "returned false"
  end
  return true
end

-- ── replicate lane_worker's transferFluid call ─────────────────────────────

local function transfer_all_fluids(fluid_tp, pull_side, hatch_side, deadline)
  local total = 0
  while computer.uptime() < deadline do
    local tanks = FluidTanks.non_empty_tanks(fluid_tp, pull_side)
    if #tanks == 0 then break end
    for _, tank in ipairs(tanks) do
      local ok, moved = pcall(fluid_tp.transferFluid, pull_side, hatch_side, tank.amount)
      if ok and moved and moved > 0 then
        log("  transferred %s mB (%s)", tostring(moved), tostring(tank.name))
        total = total + moved
      elseif not ok then
        log("  transferFluid error: %s", tostring(moved))
      else
        log("  transferFluid returned 0 for %s (%s mB)", tostring(tank.name), tostring(tank.amount))
      end
      os.sleep(0.05)
    end
  end
  return total
end

-- ── main ───────────────────────────────────────────────────────────────────

local function run(args)
  local machine_id = args[1] or "machine_01"
  local out_file = args[2]

  if out_file then log_open(out_file) end

  log("=== pull_through %s | machine=%s ===", BUILD, machine_id)

  -- Resolve machine from config
  local m
  for _, mc in ipairs(Config.machines or {}) do
    if mc.id == machine_id then m = mc; break end
  end
  if not m then log("ERROR: machine '%s' not found", machine_id); return end

  -- Proxies (same as lane_worker)
  local iface, if_err = proxy(m.interface_address, "me_interface")
  local item_tp, it_err = proxy(LaneSides.item_transposer_address(m), "transposer")
  local fluid_tp, ft_err = proxy(LaneSides.fluid_transposer_address(m), "transposer")

  log("iface    = %s (%s)", tostring(m.interface_address), iface and "OK" or if_err or "MISSING")
  log("item_tp  = %s (%s)", tostring(LaneSides.item_transposer_address(m)), item_tp and "OK" or it_err or "MISSING")
  log("fluid_tp = %s (%s)", tostring(LaneSides.fluid_transposer_address(m)), fluid_tp and "OK" or ft_err or "MISSING")

  -- Sides (same as lane_worker)
  local item_pull  = LaneSides.central_item_pull_side(m)
  local fluid_pull = LaneSides.central_fluid_pull_side(m)
  local bus_side   = LaneSides.bus_side(m)
  local hatch_side = LaneSides.fluid_hatch_side(m)

  log("sides: item_pull=%d fluid_pull=%d bus=%d hatch=%d", item_pull, fluid_pull, bus_side, hatch_side)

  -- DB config (same as lane_worker)
  local db_addr = Config.database_address
  if not db_addr or db_addr == "" or db_addr:find("SET_", 1, true) then
    log("ERROR: database_address is placeholder — set real UUID in config.lua")
    return
  end

  -- ── Step 1: Show current fluid configs on the interface ──
  log("── Step 1: current interface fluid configs ──")
  if iface and iface.getFluidInterfaceConfiguration then
    local found = false
    for side = 0, 5 do
      local ok, cfg = pcall(iface.getFluidInterfaceConfiguration, side)
      if ok and cfg then
        -- config can be {address, slot} or just a boolean false
        local addr = cfg
        local slot = nil
        if type(cfg) == "table" then
          addr = cfg.address or cfg[1]
          slot = cfg.slot or cfg[2]
        end
        if addr and addr ~= "" and addr ~= false then
          log("  side %d: addr=%s slot=%s", side, tostring(addr), tostring(slot))
          found = true
        end
      end
    end
    if not found then
      log("  (no fluid configs found on any side)")
    end
  end

  -- ── Step 2: Show current tank state on BOTH sides ──
  log("── Step 2: fluid transposer tank state ──")
  if not fluid_tp then
    log("  ERROR: no fluid transposer — cannot proceed")
    return
  end
  dump_tanks(fluid_tp, fluid_pull, "pull")
  dump_tanks(fluid_tp, hatch_side, "hatch")

  -- ── Step 3: Check what getFluidInTank returns on the pull side ──
  log("── Step 3: raw getFluidInTank on pull side %d ──", fluid_pull)
  local ok_raw, raw_tanks = pcall(fluid_tp.getFluidInTank, fluid_pull)
  log("  pcall ok=%s", tostring(ok_raw))
  if ok_raw then
    log("  type=%s", type(raw_tanks))
    if type(raw_tanks) == "table" then
      if raw_tanks.amount ~= nil then
        log("  single tank: %s mB (%s)", tostring(raw_tanks.amount), tostring(raw_tanks.name or raw_tanks.label or "?"))
      else
        log("  %d tanks:", #raw_tanks)
        for i, t in ipairs(raw_tanks) do
          log("    [%d] name=%s amount=%s", i, tostring(t.name or t.label or "?"), tostring(t.amount))
        end
      end
    else
      log("  value: %s", tostring(raw_tanks))
    end
  else
    log("  ERROR: %s", tostring(raw_tanks))
  end

  -- Also check getTankLevel
  local ok_gtl, gtl = pcall(fluid_tp.getTankLevel, fluid_pull)
  log("  getTankLevel(side=%d): ok=%s value=%s", fluid_pull, tostring(ok_gtl), tostring(gtl))
  ok_gtl, gtl = pcall(fluid_tp.getTankLevel, fluid_pull, 1)
  log("  getTankLevel(side=%d, 1): ok=%s value=%s", fluid_pull, tostring(ok_gtl), tostring(gtl))

  -- ── Step 4: Find an existing fluid config to test with ──
  log("── Step 4: test stock+deliver ──")

  -- Use the first fluid config we found on any side, but re-apply to fluid_pull side
  local test_db_slot = nil
  local test_side = nil
  for side = 0, 5 do
    local ok, cfg = pcall(iface.getFluidInterfaceConfiguration, side)
    if ok and cfg then
      if type(cfg) == "table" then
        test_db_slot = cfg.slot or cfg[2]
        test_side = side
      end
      if test_db_slot then break end
    end
  end

  if not test_db_slot then
    log("  No existing fluid config found on any side.")
    log("  Configure one via the interface GUI, then re-run this test.")
    log("  Or manually in the Lua prompt:")
    log("    iface.setFluidInterfaceConfiguration(%d, db_addr, db_slot)", fluid_pull)
    return
  end

  log("  Found existing config on side %d (db_slot=%s)", test_side, tostring(test_db_slot))
  log("  Will reconfigure on pull side %d", fluid_pull)

  -- First clear the pull side
  pcall(iface.setFluidInterfaceConfiguration, fluid_pull)

  -- Stock the fluid on the pull side
  local ok_stock, stock_err = stock_fluid_slot(iface, fluid_pull, db_addr, test_db_slot)
  if not ok_stock then
    log("  stock_fluid_slot FAILED: %s", stock_err)
    return
  end
  log("  stock_fluid_slot OK (side=%d addr=%s slot=%s)", fluid_pull, db_addr, tostring(test_db_slot))

  -- ── Step 5: Poll for delivery ──
  log("── Step 5: polling delivery (15s timeout) ──")
  local deadline = computer.uptime() + 15
  local delivered = false
  while computer.uptime() < deadline do
    local lvl = FluidTanks.tank_level(fluid_tp, fluid_pull)
    if lvl > 0 then
      delivered = true
      log("  DELIVERED after %.1fs", 15 - (deadline - computer.uptime()))
      break
    end
    os.sleep(0.5)
  end

  if delivered then
    dump_tanks(fluid_tp, fluid_pull, "pull (after delivery)")
  else
    log("  NOT DELIVERED after 15s")
    log("  Final state:")
    dump_tanks(fluid_tp, fluid_pull, "pull (timeout)")
    dump_tanks(fluid_tp, hatch_side, "hatch (timeout)")
    log("  Check: is the dual IF correctly configured?")
    log("    - Did AE2 craft/stock the fluid?")
    log("    - Is the transposer adjacent to side %d of the dual IF?", fluid_pull)
    return
  end

  -- ── Step 6: Transfer to hatch ──
  log("── Step 6: transfer pull(%d) → hatch(%d) ──", fluid_pull, hatch_side)
  local before_hatch = FluidTanks.tank_level(fluid_tp, hatch_side)
  local xfer_deadline = computer.uptime() + 10
  local total = transfer_all_fluids(fluid_tp, fluid_pull, hatch_side, xfer_deadline)
  log("  total transferred: %s mB", tostring(total))

  log("── After transfer ──")
  dump_tanks(fluid_tp, fluid_pull, "pull")
  dump_tanks(fluid_tp, hatch_side, "hatch")

  -- ── Step 7: Cleanup ──
  log("── Step 7: cleanup ──")
  pcall(iface.setFluidInterfaceConfiguration, fluid_pull)
  log("  cleared fluid config on side %d", fluid_pull)

  log("=== done ===")
  if out_file then log_close() end
end

local ok, err = pcall(run, {...})
if not ok then
  print("[pull_through] crashed: " .. tostring(err))
end
