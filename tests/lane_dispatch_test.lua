#!/usr/bin/env lua
--[[
  AutoOS — Lane dispatch FSM tests (LCR per-lane + dual transposer)

  Run: lua55 tests\lane_dispatch_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/lane_dispatch_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local LaneDispatch = require("lane_dispatch")
local CircuitManager = require("circuit_manager")

local ESC = string.char(27)
local function color(c, t) return ESC .. "[" .. c .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write("  -  " .. tostring(detail)) end
  io.write("\n")
end

local function stack(damage, size)
  return { name = "gregtech:gt.integrated_circuit", damage = damage, size = size or 1 }
end

local function new_item_tp(inv_sizes, items)
  local inv = items or {}
  local tp = {}
  function tp.getInventorySize(side) return inv_sizes[side] or 0 end
  function tp.getStackInSlot(side, slot)
    return inv[side] and inv[side][slot] or nil
  end
  function tp.getSlotStackSize(side, slot)
    local st = tp.getStackInSlot(side, slot)
    return st and (st.size or 0) or 0
  end
  function tp.transferItem(from_side, to_side, count, from_slot, to_slot)
    if not inv[from_side] or not inv[from_side][from_slot] then return 0 end
    local src = inv[from_side][from_slot]
    local max_to = inv_sizes[to_side] or 0
    if max_to < 1 then return 0 end
    local dest = to_slot
    if not dest then
      for i = 1, max_to do
        if not inv[to_side] or not inv[to_side][i] then dest = i; break end
      end
    end
    if not dest then return 0 end
    inv[to_side] = inv[to_side] or {}
    if inv[to_side][dest] then return 0 end
    inv[to_side][dest] = { name = src.name, damage = src.damage, size = math.min(count, src.size or 1) }
    if (src.size or 1) <= count then
      inv[from_side][from_slot] = nil
    else
      src.size = src.size - count
    end
    return 1
  end
  return tp, inv
end

local function new_fluid_tp(tanks)
  local tank_data = tanks or {}
  local tp = {}
  function tp.getTankCount(side)
    return tank_data[side] and #tank_data[side] or 0
  end
  function tp.getTankLevel(side, idx)
    local t = tank_data[side] and tank_data[side][idx or 1]
    return t and t.amount or 0
  end
  function tp.transferFluid(from_side, to_side, amount)
    local from = tank_data[from_side] and tank_data[from_side][1]
    if not from or from.amount <= 0 then return false end
    tank_data[to_side] = tank_data[to_side] or {}
    tank_data[to_side][1] = tank_data[to_side][1] or { amount = 0, name = from.name }
    local move = math.min(amount, from.amount)
    from.amount = from.amount - move
    tank_data[to_side][1].amount = tank_data[to_side][1].amount + move
    return move
  end
  return tp, tank_data
end

local function make_fixture(f)
  local now = 0
  local item_tp, item_inv = new_item_tp(f.item_sizes or { [1] = 9, [4] = 9 }, f.item_inv or {})
  local fluid_tp, fluid_tanks = new_fluid_tp(f.fluid_tanks or {})

  local component = {
    proxy = function(address)
      if address == "item-tp" then return item_tp end
      if address == "fluid-tp" then return fluid_tp end
      if address == "gt-1" then return {} end
      error("unknown " .. tostring(address))
    end,
    list = function()
      return { ["item-tp"] = "transposer", ["fluid-tp"] = "transposer", ["gt-1"] = "gt_machine" }
    end,
  }

  local cfg = {
    input_mode = "per_lane",
    completion_mode = "both",
    chest_slot_start = 1,
    circuit_bus_slot = 1,
    settle_s = 0.1,
    staging_timeout_s = 30,
    circuit_item_name = "gregtech:gt.integrated_circuit",
    machines = {
      {
        id = "machine_01",
        gt_address = "gt-1",
        item_transposer_address = "item-tp",
        fluid_transposer_address = "fluid-tp",
        side_buffer = 1,
        side_bus_b = 4,
        side_return = 1,
        side_fluid_buffer = 1,
        side_fluid_hatch = 4,
      },
    },
  }

  local manager = CircuitManager.new({ config = cfg, component = component })
  local dispatch = LaneDispatch.new({
    config = cfg,
    component = component,
    circuit_manager = manager,
    now = function() return now end,
    sleep = function() end,
    log = function() end,
  })

  return {
    dispatch = dispatch,
    machine = cfg.machines[1],
    item_tp = item_tp,
    item_inv = item_inv,
    fluid_tanks = fluid_tanks,
    advance = function(s) now = now + s end,
  }
end

io.write("\n" .. bold("AutoOS Lane Dispatch Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- idle stays idle without buffer ------------------------------------------------
do
  local fx = make_fixture({})
  local fast, ev = fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  check("idle without buffer", fast == false and #ev == 0)
end

-- buffer -> settle -> transfer --------------------------------------------------
do
  local fx = make_fixture({
    item_inv = { [1] = { [1] = stack(18) }, [4] = {} },
    fluid_tanks = { [1] = { { amount = 1000, name = "fluid" } }, [4] = {} },
  })
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  check("buffer triggers settle", fx.dispatch:get_lane_debug("machine_01").state == "settle")
  fx.advance(0.15)
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  check("settle -> transfer", fx.dispatch:get_lane_debug("machine_01").state == "transfer")
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  check("transfer moves item to bus", fx.item_tp.getStackInSlot(4, 1) ~= nil)
  check("transfer moves fluid to hatch", (fx.fluid_tanks[4] and fx.fluid_tanks[4][1].amount or 0) > 0)
  check("after transfer -> wait_complete", fx.dispatch:get_lane_debug("machine_01").state == "wait_complete")
end

-- completion via adapter edge + drain -------------------------------------------
do
  local fx = make_fixture({
    item_inv = { [1] = { [1] = stack(18) }, [4] = {} },
    fluid_tanks = { [1] = { { amount = 500, name = "f" } }, [4] = {} },
  })
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  fx.advance(0.2)
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  -- simulate processing: active then drain
  fx.item_inv[4] = { [1] = stack(18) }
  fx.fluid_tanks[4] = { { amount = 0 } }
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = true, has_work = false })
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  local _, ev = fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  local extract = false
  for _, e in ipairs(ev) do if e.type == "extract_start" then extract = true end end
  check("adapter+drain triggers extract", extract or fx.dispatch:get_lane_debug("machine_01").state == "extract" or fx.dispatch:get_lane_debug("machine_01").state == "wait_import")
end

-- full cycle extract + import ---------------------------------------------------
do
  local fx = make_fixture({
    item_inv = { [1] = { [1] = stack(14) }, [4] = {} },
    fluid_tanks = {},
  })
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  fx.advance(0.2)
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  fx.item_inv[4] = { [1] = stack(14) }
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = true, has_work = false })
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  -- circuit on return face — simulate AE import
  fx.item_inv[1] = {}
  local _, ev = fx.dispatch:tick_lane(fx.machine, { available = true, healthy = true, active = false, has_work = false })
  local ok_ev = false
  for _, e in ipairs(ev) do if e.type == "recover_ok" then ok_ev = true end end
  check("full cycle recover_ok", ok_ev or fx.dispatch:get_lane_debug("machine_01").state == "idle")
end

-- round-robin order -------------------------------------------------------------
do
  local dispatch = LaneDispatch.new({
    config = { machines = { { id = "a" }, { id = "b" }, { id = "c" } } },
    component = { proxy = function() return {} end, list = function() return {} end },
    circuit_manager = CircuitManager.new({
      config = { circuit_item_name = "gregtech:gt.integrated_circuit", machines = {} },
      component = { proxy = function() return {} end, list = function() return {} end },
    }),
    now = function() return 0 end,
  })
  local o1 = dispatch:lane_order({ { id = "a" }, { id = "b" }, { id = "c" } })
  dispatch:advance_round_robin({ { id = "a" }, { id = "b" }, { id = "c" } })
  local o2 = dispatch:lane_order({ { id = "a" }, { id = "b" }, { id = "c" } })
  check("round-robin rotates", o1[1].id == "a" and o2[1].id == "b")
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Lane dispatch result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
