--[[
  AutoOS — Pull-through test: central buffer → dual IF → transposer → hatch
  Usage:
    loadfile("/home/subnet_broker/pull_through.lua")("machine_01")
    loadfile("/home/subnet_broker/pull_through.lua")("machine_01", "pull.txt")
    loadfile("/home/subnet_broker/pull_through.lua")("machine_01", "pull.txt", 3)  -- db_slot=3
]]

local BUILD = "2026-06-19"

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

local LOG_FILE = nil
local function log(fmt, ...)
  local msg = string.format("[pull_through] " .. fmt, ...)
  print(msg)
  if LOG_FILE then LOG_FILE:write(msg .. "\n"); LOG_FILE:flush() end
end

local function log_open(fn)
  LOG_FILE = io.open("/home/subnet_broker/" .. fn, "w")
  if LOG_FILE then log("log opened: %s", fn) end
end
local function log_close()
  if LOG_FILE then LOG_FILE:close(); LOG_FILE = nil end
end

-- ── proxies ────────────────────────────────────────────────────────────────

local function proxy(addr, ptype)
  if not addr or addr == "" then return nil end
  local ok, p = pcall(component.proxy, addr, ptype)
  if ok and p then return p end
  ok, p = pcall(component.proxy, addr)
  return ok and p or nil
end

-- ── helpers ────────────────────────────────────────────────────────────────

local function dump_tanks(tp, side, label)
  if not tp then log("  %s: no transposer", label); return end
  local lvl = FluidTanks.tank_level(tp, side)
  local cap = FluidTanks.tank_capacity(tp, side)
  log("  %s (side %d): level=%s cap=%s", label, side, tostring(lvl), tostring(cap or "?"))
  for _, row in ipairs(FluidTanks.non_empty_tanks(tp, side)) do
    log("    tank[%d] %s : %s mB", row.idx, tostring(row.name), tostring(row.amount))
  end
end

local function dump_raw_getFluidInTank(tp, side, label)
  if not tp then log("  %s: no transposer", label); return end
  local ok, val = pcall(tp.getFluidInTank, side)
  log("  %s getFluidInTank(%d): ok=%s", label, side, tostring(ok))
  if not ok then
    log("    ERROR: %s", tostring(val))
    return
  end
  if type(val) == "table" then
    if val.amount ~= nil then
      log("    single: name=%s amount=%s", tostring(val.name or val.label or "?"), tostring(val.amount))
    else
      log("    %d entries:", #val)
      for i, t in ipairs(val) do
        log("      [%d] name=%s amount=%s label=%s",
          i, tostring(t.name or "?"), tostring(t.amount), tostring(t.label or "-"))
      end
    end
  else
    log("    raw value: %s", tostring(val))
  end
end

-- ── main ───────────────────────────────────────────────────────────────────

local function run(args)
  local machine_id = args[1] or "machine_01"
  local out_file   = args[2]  -- e.g. "pull.txt"
  local manual_slot = tonumber(args[3])  -- optional db_slot override

  if out_file then log_open(out_file) end

  local function do_run()
  -- ── begin do_run (return on early exit, cleanup always runs) ──

  log("=== pull_through %s | machine=%s ===", BUILD, machine_id)

  -- Resolve machine
  local m
  for _, mc in ipairs(Config.machines or {}) do
    if mc.id == machine_id then m = mc; break end
  end
  if not m then log("ERROR: machine '%s' not found", machine_id); return end

  -- ── Proxies ──
  local iface   = proxy(m.interface_address, "me_interface")
  local item_tp = proxy(LaneSides.item_transposer_address(m), "transposer")
  local fluid_tp = proxy(LaneSides.fluid_transposer_address(m), "transposer")
  local fluid_adapter = nil
  local central = Config.central or {}
  if central.fluid_adapter_address and central.fluid_adapter_address ~= "" then
    fluid_adapter = proxy(central.fluid_adapter_address, "transposer")
  end
  local db = proxy(Config.database_address, "database")  -- to look up fluid entries

  log("iface    = %s", iface and "OK" or "MISSING")
  log("item_tp  = %s", item_tp and "OK" or "MISSING")
  log("fluid_tp = %s", fluid_tp and "OK" or "MISSING")
  log("fluid_ad = %s (%s)", central.fluid_adapter_address or "(none)", fluid_adapter and "OK" or "MISSING")
  log("db       = %s (%s)", Config.database_address or "(none)", db and "OK" or "MISSING")

  -- ── Sides ──
  local item_pull  = LaneSides.central_item_pull_side(m)
  local fluid_pull = LaneSides.central_fluid_pull_side(m)
  local hatch_side = LaneSides.fluid_hatch_side(m)
  local fluid_ad_side = central.fluid_adapter_side or 0

  log("sides: item_pull=%d fluid_pull=%d hatch=%d fluid_ad=%d",
    item_pull, fluid_pull, hatch_side, fluid_ad_side)

  -- ── Step 1: Central fluid buffer ──
  log("── Step 1: central fluid buffer (adapter) ──")
  if fluid_adapter then
    dump_tanks(fluid_adapter, fluid_ad_side, "central_tank")
    dump_raw_getFluidInTank(fluid_adapter, fluid_ad_side, "central_raw")
  else
    log("  no fluid adapter configured (central.fluid_adapter_address)")
  end

  -- ── Step 2: Current interface fluid configs (raw dump) ──
  log("── Step 2: interface fluid configs (raw) ──")
  if iface and iface.getFluidInterfaceConfiguration then
    for side = 0, 5 do
      local ok, cfg = pcall(iface.getFluidInterfaceConfiguration, side)
      local cfg_type = type(cfg)
      log("  side %d: ok=%s type=%s", side, tostring(ok), cfg_type)
      if ok and cfg_type == "table" then
        for k, v in pairs(cfg) do
          log("    .%s = %s", tostring(k), tostring(v))
        end
      elseif ok and cfg_type ~= "nil" then
        log("    value = %s", tostring(cfg))
      end
    end
  else
    log("  getFluidInterfaceConfiguration not available")
  end

  -- ── Step 3: Current tank state on pull + hatch ──
  log("── Step 3: transposer tank state ──")
  if fluid_tp then
    dump_tanks(fluid_tp, fluid_pull, "pull")
    dump_raw_getFluidInTank(fluid_tp, fluid_pull, "pull_raw")
    dump_tanks(fluid_tp, hatch_side, "hatch")
  else
    log("  no fluid transposer")
    return
  end

  -- ── Step 3.5: Fast path — fluid already on pull side? ──
  log("── Step 3.5: check if fluid already on pull side ──")
  local already_there = FluidTanks.tank_level(fluid_tp, fluid_pull)
  local skip_stock = false
  if already_there > 0 then
    log("  fluid already on pull side (level=%s) — skipping stock", tostring(already_there))
    skip_stock = true
  else
    log("  pull side empty — need to stock + wait for delivery")
  end

  if not skip_stock then
  -- ══════════════════════════════════════════════════════════════════════
  -- Steps 4-6 only run if pull side is empty
  -- ══════════════════════════════════════════════════════════════════════

  -- ── Step 4: Find or create a fluid DB entry ──
  log("── Step 4: find/create DB entry ──")
  local db_addr = Config.database_address
  if not db_addr or db_addr == "" or db_addr:find("SET_", 1, true) then
    log("  database_address is placeholder — set in config.lua")
    return
  end

  local stock_slot = manual_slot
  local stock_label = "manual"

  -- Helper: find an empty DB slot
  local function find_empty_db_slot()
    if not db or not db.get then return nil end
    for slot = 1, (Config.database_slot_count or 9) do
      local ok_s, entry = pcall(db.get, slot)
      if not ok_s or entry == nil then return slot end
    end
    return nil
  end

  -- Helper: try to create a fluid DB entry from a fluid drop in the ME network
  local function create_fluid_entry(fluid_name)
    if not iface or not iface.store then
      return nil, "iface missing store"
    end
    if not iface.getItemsInNetwork then
      return nil, "iface missing getItemsInNetwork"
    end

    -- Try multiple item names for fluid drops (different GTNH versions use
    -- different names for the fluid drop item)
    local drop_names = { "ae2fc:fluid_drop", "ae2fc:fluid_drop1", "ae2fc:fluid_drop2" }
    local drops = nil
    for _, dn in ipairs(drop_names) do
      drops = iface.getItemsInNetwork({ name = dn })
      if type(drops) == "table" and #drops > 0 then
        log("  found %d fluid drops via '%s'", #drops, dn)
        break
      end
      drops = nil
    end
    if not drops then
      -- Show what IS available for debugging
      log("  no fluid_drop items found — listing first 10 items in network:")
      local all = iface.getItemsInNetwork({})
      if type(all) == "table" then
        local shown = 0
        for _, item in ipairs(all) do
          if shown >= 10 then break end
          shown = shown + 1
          log("    [%d] name=%s label=%s damage=%s",
            shown, tostring(item.name or "?"), tostring(item.label or "-"), tostring(item.damage or 0))
        end
        if #all == 0 then log("    (no items in network)") end
      else
        log("    getItemsInNetwork({}) returned: %s", tostring(all))
      end
      return nil, "no fluid_drop items in ME network"
    end

    -- Match: strip "drop of " prefix from drop label, compare against fluid name
    local fname = fluid_name:lower():gsub("^drop of ", ""):gsub("^molten ", "")
    for _, drop in ipairs(drops) do
      local dlabel = drop.label and drop.label:lower():gsub("^drop of ", ""):gsub("^molten ", "")
      if dlabel and (dlabel == fname or dlabel:find(fname, 1, true) or fname:find(dlabel, 1, true)) then
        local empty = find_empty_db_slot()
        if not empty then return nil, "no empty DB slots" end
        local filter = { name = drop.name, damage = drop.damage or 0 }
        if drop.label then filter.label = drop.label end
        local ok_s = iface.store(filter, db_addr, empty, 1)
        if ok_s then
          log("  created DB entry: slot %d = %s", empty, tostring(drop.label or drop.name))
          return empty, drop.label or drop.name
        end
        return nil, "iface.store returned false for slot " .. tostring(empty)
      end
    end

    -- Show what drops are available for manual matching
    log("  no match for '%s' — available drops:", fluid_name)
    for i, drop in ipairs(drops) do
      if i > 5 then log("    ... and %d more", #drops - 5); break end
      log("    [%d] name=%s label=%s", i, tostring(drop.name), tostring(drop.label or "-"))
    end
    return nil, "no fluid_drop matching '" .. fluid_name .. "'"
  end

  if not stock_slot then
    -- First: try to match fluids from the central tank to existing DB entries
    if fluid_adapter then
      local tanks = FluidTanks.non_empty_tanks(fluid_adapter, fluid_ad_side)
      for _, tank in ipairs(tanks) do
        local raw = tostring(tank.name or "")
        for slot = 1, (Config.database_slot_count or 9) do
          local ok_s, entry = pcall(db.get, slot)
          if ok_s and type(entry) == "table" then
            local ename = tostring(entry.name or entry.label or "")
            if ename ~= "" and (raw:lower():find(ename:lower(), 1, true) or ename:lower():find(raw:lower(), 1, true)) then
              stock_slot = slot
              stock_label = ename
              log("  matched tank '%s' → DB slot %d (%s)", raw, slot, ename)
              goto got_slot
            end
          end
        end
      end

      -- No match found — try to create entries for fluids in the central tank
      log("  no matching DB entries found — attempting to create them")
      for _, tank in ipairs(FluidTanks.non_empty_tanks(fluid_adapter, fluid_ad_side)) do
        local raw = tostring(tank.name or "")
        local slot, err = create_fluid_entry(raw)
        if slot then
          stock_slot = slot
          stock_label = err  -- err holds the label on success
          log("  created entry for '%s' → slot %d", raw, slot)
          goto got_slot
        else
          log("  could not create entry for '%s': %s", raw, tostring(err))
        end
      end
    end

    -- Fallback: list all DB slots
    log("  no usable DB entry — listing all DB slots:")
    if db then
      for slot = 1, (Config.database_slot_count or 9) do
        local ok_s, entry = pcall(db.get, slot)
        if ok_s and type(entry) == "table" then
          local ename = tostring(entry.name or entry.label or "?")
          log("    slot %d: %s", slot, ename)
        else
          log("    slot %d: (empty)", slot)
        end
      end
    end
    log("  re-run with db_slot as 3rd arg: pull_through(\"machine_01\", \"pull.txt\", N)")
    return
  end

  ::got_slot::
  if not stock_slot then
    log("  no DB slot found — pass db_slot as 3rd argument")
    return
  end
  log("  using db_slot=%s label=%s", tostring(stock_slot), stock_label)

  -- ── Step 5: Stock the fluid on the pull side ──
  log("── Step 5: stock fluid on pull side %d ──", fluid_pull)
  if not iface or not iface.setFluidInterfaceConfiguration then
    log("  ERROR: no setFluidInterfaceConfiguration")
    return
  end

  -- Clear existing config on pull side first
  pcall(iface.setFluidInterfaceConfiguration, fluid_pull)
  log("  cleared side %d", fluid_pull)

  -- Stock
  local ok_stock, stock_err = pcall(iface.setFluidInterfaceConfiguration, fluid_pull, db_addr, stock_slot)
  if not ok_stock or stock_err == false then
    log("  stock FAILED: ok=%s err=%s", tostring(ok_stock), tostring(stock_err))
    return
  end
  log("  stock OK: side=%d addr=%s slot=%s", fluid_pull, db_addr, tostring(stock_slot))

  -- ── Step 6: Poll for delivery ──
  log("── Step 6: polling delivery (20s timeout) ──")
  local deadline = computer.uptime() + 20
  local delivered = false
  while computer.uptime() < deadline do
    local lvl = FluidTanks.tank_level(fluid_tp, fluid_pull)
    if lvl > 0 then
      delivered = true
      local elapsed = 20 - (deadline - computer.uptime())
      log("  DELIVERED after %.1fs (level=%s)", elapsed, tostring(lvl))
      break
    end
    os.sleep(0.25)
  end

  if not delivered then
    log("  NOT DELIVERED after 20s — checking final state:")
    dump_tanks(fluid_tp, fluid_pull, "pull (timeout)")
    dump_raw_getFluidInTank(fluid_tp, fluid_pull, "pull_raw (timeout)")
    log("  Possible issues:")
    log("    - AE2 hasn't crafted/stocked the fluid yet")
    log("    - fluid_pull_side (%d) doesn't match the dual IF side the transposer sees", fluid_pull)
    log("    - setFluidInterfaceConfiguration needs a DIFFERENT first arg")
    log("  Try running again with items (they work) as a control test")
    return
  end

  end  -- if not skip_stock (Steps 4-6)

  -- ── Step 7: Transfer to hatch ──
  log("── Step 7: transfer pull(%d) → hatch(%d) ──", fluid_pull, hatch_side)
  local before_hatch = FluidTanks.tank_level(fluid_tp, hatch_side)
  log("  hatch before: %s", tostring(before_hatch))

  local total = 0
  local xfer_deadline = computer.uptime() + 10
  while computer.uptime() < xfer_deadline do
    local tanks = FluidTanks.non_empty_tanks(fluid_tp, fluid_pull)
    if #tanks == 0 then break end
    for _, tank in ipairs(tanks) do
      local ok, moved = pcall(fluid_tp.transferFluid, fluid_pull, hatch_side, tank.amount)
      if ok and type(moved) == "number" and moved > 0 then
        log("  transferred %s mB (%s)", tostring(moved), tostring(tank.name))
        total = total + moved
      else
        log("  transferFluid: ok=%s moved=%s (name=%s amount=%s)",
          tostring(ok), tostring(moved), tostring(tank.name), tostring(tank.amount))
      end
      os.sleep(0.05)
    end
  end

  log("  total transferred: %s mB", tostring(total))
  log("── After transfer ──")
  dump_tanks(fluid_tp, fluid_pull, "pull")
  dump_tanks(fluid_tp, hatch_side, "hatch")
  local after_hatch = FluidTanks.tank_level(fluid_tp, hatch_side)
  log("  hatch delta: %s → %s", tostring(before_hatch), tostring(after_hatch))

  -- ── Step 8: Cleanup ──
  log("── Step 8: cleanup ──")
  pcall(iface.setFluidInterfaceConfiguration, fluid_pull)
  log("  cleared fluid config on side %d", fluid_pull)

  -- ── end do_run ──
  end  -- do_run

  local ok_do, do_err = pcall(do_run)
  if not ok_do then
    log("ERROR: %s", tostring(do_err))
  end
  log("=== done ===")
  if out_file then log_close() end
end

local ok, err = pcall(run, {...})
if not ok then
  print("[pull_through] crashed: " .. tostring(err))
  if LOG_FILE then
    LOG_FILE:write("[pull_through] crashed: " .. tostring(err) .. "\n")
    LOG_FILE:close()
  end
end
