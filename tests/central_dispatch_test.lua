#!/usr/bin/env lua
--[[
  AutoOS — Central buffer adapter + stability tests

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

local function new_adapter(inv)
  local adapter = {}
  function adapter.getInventorySize(side) return inv[side] and inv[side].size or 0 end
  function adapter.getStackInSlot(side, slot)
    return inv[side] and inv[side].slots and inv[side].slots[slot] or nil
  end
  function adapter.getSlotStackSize(side, slot)
    local st = adapter.getStackInSlot(side, slot)
    return st and (st.size or 0) or 0
  end
  return adapter
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

local function make_fixture(opts)
  opts = opts or {}
  local now = opts.now or 0
  local adapter_side = 0
  local chest_inv = opts.chest_inv or {
    [adapter_side] = { size = 9, slots = { [1] = stack(18) } },
  }

  local lane1_buf, lane1_bus = {}, {}
  local lane1_item, lane1_item_inv = new_item_tp(
    opts.lane1_item_sizes or { [2] = 9, [0] = 9, [4] = 9, [5] = 9 },
    opts.lane1_item_inv or { [2] = lane1_buf, [0] = lane1_bus, [4] = {}, [5] = {} })
  local lane1_fluid, lane1_fluid_tanks = new_fluid_tp(opts.lane1_fluid_tanks or { [2] = {} })

  local lane2_item, lane2_item_inv = new_item_tp(
    opts.lane2_item_sizes or { [2] = 9, [4] = 9, [5] = 9 },
    opts.lane2_item_inv or { [2] = {}, [4] = {}, [5] = {} })
  local lane2_fluid = new_fluid_tp({ [2] = {} })

  local item_adapter = new_adapter(chest_inv)

  local component = {
    proxy = function(address)
      if address == "item-adapter" then return item_adapter end
      if address == "lane1-item" then return lane1_item end
      if address == "lane1-fluid" then return lane1_fluid end
      if address == "lane2-item" then return lane2_item end
      if address == "lane2-fluid" then return lane2_fluid end
      if address == "gt-1" or address == "gt-2" then return {} end
      error("unknown " .. tostring(address))
    end,
    list = function()
      return {
        ["item-adapter"] = "adapter",
        ["lane1-item"] = "transposer", ["lane1-fluid"] = "transposer",
        ["lane2-item"] = "transposer", ["lane2-fluid"] = "transposer",
      }
    end,
  }

  local cfg = {
    input_mode = "central",
    do_round_robin = true,
    completion_mode = "both",
    chest_slot_start = 1,
    circuit_bus_slot = 1,
    settle_s = 0.05,
    staging_timeout_s = 30,
    circuit_item_name = "gregtech:gt.integrated_circuit",
    require_empty_return = true,
    central = {
      buffer_adapter_address = "item-adapter",
      buffer_adapter_side = adapter_side,
      chest_slot_start = 1,
      max_circuits_in_buffer = 1,
      stabilize_s = opts.stabilize_s or 3.0,
    },
    machines = {
      {
        id = "machine_01", gt_address = "gt-1",
        item_transposer_address = "lane1-item",
        fluid_transposer_address = "lane1-fluid",
        side_buffer = 2, side_bus_b = 0, side_return = 5,
        side_fluid_buffer = 2, side_fluid_hatch = 0,
      },
      {
        id = "machine_02", gt_address = "gt-2",
        item_transposer_address = "lane2-item",
        fluid_transposer_address = "lane2-fluid",
        side_buffer = 2, side_bus_b = 4, side_return = 5,
        side_fluid_buffer = 2, side_fluid_hatch = 0,
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
    now = function() return now end, log = function() end,
  })

  local poll_idle = { available = true, healthy = true, active = false, has_work = false }
  local results = { machine_01 = poll_idle, machine_02 = poll_idle }

  return {
    central = central,
    lane_dispatch = lane_dispatch,
    cfg = cfg,
    results = results,
    poll_idle = poll_idle,
    chest_inv = chest_inv,
    adapter_side = adapter_side,
    lane1_item_inv = lane1_item_inv,
    lane1_buf = lane1_buf,
    advance = function(s) now = now + s end,
    set_chest_slot = function(slot, st)
      chest_inv[adapter_side].slots[slot] = st
    end,
  }
end

io.write("\n" .. bold("AutoOS Central Dispatch Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- RR picks first available ------------------------------------------------------
do
  local fx = make_fixture({})
  fx.lane1_buf[1] = stack(18)
  local m = fx.central:find_available_machine_rr(fx.cfg.machines, fx.results, fx.lane_dispatch)
  check("RR finds machine_01 first", m and m.id == "machine_01")
end

-- empty chest -> idle -----------------------------------------------------------
do
  local fx = make_fixture({ chest_inv = { [0] = { size = 9, slots = {} } } })
  fx.central:tick(fx.results, fx.lane_dispatch)
  check("empty chest stays idle", fx.central:get_debug().state == "central_idle")
end

-- items -> stabilizing ----------------------------------------------------------
do
  local fx = make_fixture({})
  fx.central:tick(fx.results, fx.lane_dispatch)
  check("items trigger stabilizing", fx.central:get_debug().state == "central_stabilizing")
end

-- stability timer resets on change ----------------------------------------------
do
  local fx = make_fixture({ stabilize_s = 3.0 })
  fx.central:tick(fx.results, fx.lane_dispatch)
  fx.advance(2.0)
  fx.central:tick(fx.results, fx.lane_dispatch)
  check("not stable at 2s", fx.central:get_debug().state == "central_stabilizing")
  fx.set_chest_slot(2, stack(18))
  fx.central:tick(fx.results, fx.lane_dispatch)
  fx.advance(2.0)
  fx.central:tick(fx.results, fx.lane_dispatch)
  check("item change resets timer", fx.central:get_debug().state == "central_stabilizing")
end

-- stable 3s + staged interface -> assign ----------------------------------------
do
  local fx = make_fixture({ stabilize_s = 1.0 })
  fx.lane1_buf[1] = stack(18)
  fx.central:tick(fx.results, fx.lane_dispatch)
  fx.advance(1.1)
  local ev = fx.central:tick(fx.results, fx.lane_dispatch)
  local staged = false
  for _, e in ipairs(ev) do if e.type == "central_staged" then staged = true end end
  check("stable batch assigns lane", staged)
  check("lane enters settle/transfer path",
    fx.lane_dispatch:get_lane_debug("machine_01").state ~= "idle")
  check("central bound", fx.central:get_debug().state == "central_bound")
end

-- assign without pre-staged pull face still hands off (default) ---------------
do
  local fx = make_fixture({ stabilize_s = 0.5 })
  fx.central:tick(fx.results, fx.lane_dispatch)
  fx.advance(0.6)
  local ev = fx.central:tick(fx.results, fx.lane_dispatch)
  local staged = false
  for _, e in ipairs(ev) do if e.type == "central_staged" then staged = true end end
  check("assign without pre-staged pull face", staged or fx.central:get_debug().state == "central_bound")
end

-- central mode idle lane no buffer pickup ---------------------------------------
do
  local fx = make_fixture({})
  local fast, ev = fx.lane_dispatch:tick_lane(fx.cfg.machines[1], fx.poll_idle)
  check("central idle lane no-op", fast == false and #ev == 0)
end

-- handoff_from_central -> settle ------------------------------------------------
do
  local fx = make_fixture({})
  fx.lane1_buf[1] = stack(18)
  local ok = fx.lane_dispatch:handoff_from_central(fx.cfg.machines[1])
  check("handoff -> settle", ok and fx.lane_dispatch:get_lane_debug("machine_01").state == "settle")
end

-- handoff rejected when staging required and pull face empty --------------------
do
  local fx = make_fixture({})
  fx.cfg.central.require_interface_staging = true
  local ok = fx.lane_dispatch:handoff_from_central(fx.cfg.machines[1])
  check("staging required rejects empty pull face", not ok)
end

-- handoff without staging gate (default) ----------------------------------------
do
  local fx = make_fixture({})
  local ok = fx.lane_dispatch:handoff_from_central(fx.cfg.machines[1])
  check("no staging gate handoff ok", ok and fx.lane_dispatch:get_lane_debug("machine_01").state == "settle")
end

-- busy bus skips machine --------------------------------------------------------
do
  local fx = make_fixture({})
  fx.lane1_item_inv[0][1] = { name = "minecraft:dirt", size = 1 }
  local m = fx.central:find_available_machine_rr(fx.cfg.machines, fx.results, fx.lane_dispatch)
  check("non-empty bus skips machine_01", m and m.id == "machine_02")
end

-- failed transfer does not count as batch complete ------------------------------
do
  local fx = make_fixture({ stabilize_s = 0.5 })
  fx.cfg.staging_timeout_s = 0.3
  fx.cfg.central.interface_wait_s = 0.3
  fx.central:tick(fx.results, fx.lane_dispatch)
  fx.advance(0.6)
  fx.central:tick(fx.results, fx.lane_dispatch)
  check("bound after assign", fx.central:get_debug().state == "central_bound")
  fx.lane_dispatch:tick_lane(fx.cfg.machines[1], fx.poll_idle)
  fx.advance(0.35)
  fx.lane_dispatch:tick_lane(fx.cfg.machines[1], fx.poll_idle)
  local dbg = fx.lane_dispatch:get_lane_debug("machine_01")
  check("dual IF empty -> failed outcome", dbg.batch_outcome == "failed")
  fx.central:tick(fx.results, fx.lane_dispatch)
  check("failed handoff retries assign not idle",
    fx.central:get_debug().state == "central_assign")
  check("not batch complete on failed transfer",
    fx.central:get_debug().bound_machine == nil)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Central dispatch result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
