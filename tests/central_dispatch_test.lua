#!/usr/bin/env lua
--[[
  AutoOS — Central buffer RR dispatch tests

  Run: lua tests/central_dispatch_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/central_dispatch_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local CentralDispatch = require("central_dispatch")
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
  function tp.getStackInSlot(side, slot) return inv[side] and inv[side][slot] or nil end
  function tp.getSlotStackSize(side, slot)
    local st = tp.getStackInSlot(side, slot)
    return st and (st.size or 0) or 0
  end
  function tp.transferItem(from_side, to_side, count, from_slot)
    if not inv[from_side] or not inv[from_side][from_slot] then return 0 end
    local src = inv[from_side][from_slot]
    inv[to_side] = inv[to_side] or {}
    for i = 1, inv_sizes[to_side] or 0 do
      if not inv[to_side][i] then
        inv[to_side][i] = { name = src.name, damage = src.damage, size = math.min(count, src.size or 1) }
        inv[from_side][from_slot] = nil
        return 1
      end
    end
    return 0
  end
  return tp, inv
end

local function new_fluid_tp(tanks)
  local tank_data = tanks or {}
  local tp = {}
  function tp.getTankCount(side) return tank_data[side] and #tank_data[side] or 0 end
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

local function make_central_fixture(opts)
  opts = opts or {}
  local now = opts.now or 0
  local central_item, central_item_inv = new_item_tp(
    opts.central_item_sizes or { [2] = 9, [0] = 9, [1] = 9 },
    opts.central_item_inv or { [2] = { [1] = stack(18) } })
  local central_fluid, central_fluid_tanks = new_fluid_tp(
    opts.central_fluid_tanks or { [2] = { { amount = 1000, name = "fluid" } }, [0] = {}, [1] = {} })

  local lane1_item, lane1_item_inv = new_item_tp(
    opts.lane1_item_sizes or { [4] = 9, [5] = 9 },
    opts.lane1_item_inv or {})
  local lane1_fluid, lane1_fluid_tanks = new_fluid_tp(opts.lane1_fluid_tanks or { [0] = {} })

  local lane2_item, lane2_item_inv = new_item_tp(
    opts.lane2_item_sizes or { [4] = 9, [5] = 9 },
    opts.lane2_item_inv or {})
  local lane2_fluid, lane2_fluid_tanks = new_fluid_tp(opts.lane2_fluid_tanks or { [0] = {} })

  local component = {
    proxy = function(address)
      if address == "central-item" then return central_item end
      if address == "central-fluid" then return central_fluid end
      if address == "lane1-item" then return lane1_item end
      if address == "lane1-fluid" then return lane1_fluid end
      if address == "lane2-item" then return lane2_item end
      if address == "lane2-fluid" then return lane2_fluid end
      if address == "gt-1" or address == "gt-2" then return {} end
      error("unknown " .. tostring(address))
    end,
    list = function()
      return {
        ["central-item"] = "transposer", ["central-fluid"] = "transposer",
        ["lane1-item"] = "transposer", ["lane1-fluid"] = "transposer",
        ["lane2-item"] = "transposer", ["lane2-fluid"] = "transposer",
        ["gt-1"] = "gt_machine", ["gt-2"] = "gt_machine",
      }
    end,
  }

  local cfg = {
    input_mode = "central",
    do_round_robin = true,
    completion_mode = "both",
    chest_slot_start = 1,
    circuit_bus_slot = 1,
    settle_s = 0.1,
    staging_timeout_s = 30,
    circuit_item_name = "gregtech:gt.integrated_circuit",
    require_empty_return = true,
    central = {
      item_transposer_address = "central-item",
      fluid_transposer_address = "central-fluid",
      side_buffer = 2,
      chest_slot_start = 1,
      max_circuits_in_buffer = 1,
    },
    machines = {
      {
        id = "machine_01", gt_address = "gt-1",
        item_transposer_address = "lane1-item",
        fluid_transposer_address = "lane1-fluid",
        central_item_side = 0, central_fluid_side = 0,
        side_bus_b = 4, side_return = 5, side_fluid_hatch = 0,
      },
      {
        id = "machine_02", gt_address = "gt-2",
        item_transposer_address = "lane2-item",
        fluid_transposer_address = "lane2-fluid",
        central_item_side = 1, central_fluid_side = 1,
        side_bus_b = 4, side_return = 5, side_fluid_hatch = 0,
      },
    },
  }

  local manager = CircuitManager.new({ config = cfg, component = component })
  local lane_dispatch = LaneDispatch.new({
    config = cfg, component = component, circuit_manager = manager,
    now = function() return now end, sleep = function() end, log = function() end,
  })
  local central = CentralDispatch.new({
    config = cfg, component = component, circuit_manager = manager,
    lane_dispatch = lane_dispatch,
    now = function() return now end, sleep = function() end, log = function() end,
  })

  local poll_idle = { available = true, healthy = true, active = false, has_work = false }
  local results = { machine_01 = poll_idle, machine_02 = poll_idle }

  return {
    central = central,
    lane_dispatch = lane_dispatch,
    cfg = cfg,
    results = results,
    poll_idle = poll_idle,
    central_item_inv = central_item_inv,
    central_fluid_tanks = central_fluid_tanks,
    lane1_item_inv = lane1_item_inv,
    advance = function(s) now = now + s end,
  }
end

io.write("\n" .. bold("AutoOS Central Dispatch Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- RR picks first available ------------------------------------------------------
do
  local fx = make_central_fixture({})
  local m = fx.central:find_available_machine_rr(fx.cfg.machines, fx.results, fx.lane_dispatch)
  check("RR finds machine_01 first", m and m.id == "machine_01")
end

-- RR skips busy lane -----------------------------------------------------------
do
  local fx = make_central_fixture({})
  fx.lane_dispatch:bind_from_central("machine_01")
  local m = fx.central:find_available_machine_rr(fx.cfg.machines, fx.results, fx.lane_dispatch)
  check("RR skips busy machine_01", m and m.id == "machine_02")
end

-- RR rotates after push --------------------------------------------------------
do
  local fx = make_central_fixture({})
  fx.central:find_available_machine_rr(fx.cfg.machines, fx.results, fx.lane_dispatch)
  fx.central:_advance_rr_after_push(1, 2)
  local m = fx.central:find_available_machine_rr(fx.cfg.machines, fx.results, fx.lane_dispatch)
  check("RR rotates to machine_02", m and m.id == "machine_02")
end

-- busy bus blocks availability -------------------------------------------------
do
  local fx = make_central_fixture({
    lane1_item_inv = { [4] = { [1] = { name = "minecraft:dirt", size = 1 } } },
  })
  local m = fx.central:find_available_machine_rr(fx.cfg.machines, fx.results, fx.lane_dispatch)
  check("non-empty bus skips machine_01", m and m.id == "machine_02")
end

-- central settle -> transfer -> bind -------------------------------------------
do
  local fx = make_central_fixture({})
  fx.central:tick(fx.results, fx.lane_dispatch)
  check("buffer triggers settle", fx.central:get_debug().state == "central_settle")
  fx.advance(0.15)
  local ev = fx.central:tick(fx.results, fx.lane_dispatch)
  local staged = false
  for _, e in ipairs(ev) do if e.type == "central_staged" then staged = true end end
  check("settle assigns and stages", staged)
  check("lane bound wait_complete", fx.lane_dispatch:get_lane_debug("machine_01").state == "wait_complete")
  check("central item moved to out side", fx.central_item_inv[0] and fx.central_item_inv[0][1] ~= nil)
  check("central bound state", fx.central:get_debug().state == "central_bound")
end

-- no machine available -> wait -------------------------------------------------
do
  local fx = make_central_fixture({})
  fx.lane_dispatch:bind_from_central("machine_01")
  fx.lane_dispatch:bind_from_central("machine_02")
  fx.central:tick(fx.results, fx.lane_dispatch)
  fx.advance(0.15)
  local ev = fx.central:tick(fx.results, fx.lane_dispatch)
  local wait_ev = false
  for _, e in ipairs(ev) do if e.type == "central_wait_output" then wait_ev = true end end
  check("all busy -> CENTRAL_WAIT_OUTPUT", wait_ev)
end

-- central mode: idle lane skips buffer pickup ----------------------------------
do
  local fx = make_central_fixture({})
  local fast, ev = fx.lane_dispatch:tick_lane(fx.cfg.machines[1], fx.poll_idle)
  check("central idle lane no-op", fast == false and #ev == 0)
end

-- bind_from_central handoff ----------------------------------------------------
do
  local fx = make_central_fixture({})
  fx.lane_dispatch:bind_from_central("machine_01")
  check("bind_from_central -> wait_complete",
    fx.lane_dispatch:get_lane_debug("machine_01").state == "wait_complete")
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Central dispatch result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
