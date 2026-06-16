#!/usr/bin/env lua
--[[
  AutoOS — Circuit loop FSM tests

  Run: lua55 tests\circuit_loop_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/circuit_loop_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local CircuitLoop = require("circuit_loop")
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

local function stack(damage)
  return { name = "gregtech:gt.integrated_circuit", damage = damage, size = 1 }
end

local function new_transposer(inv_sizes, items)
  local tp = {}
  local inv = items or {}
  function tp.getInventorySize(side) return inv_sizes[side] or 0 end
  function tp.getStackInSlot(side, slot)
    return inv[side] and inv[side][slot] or nil
  end
  function tp.transferItem(from_side, to_side, count, from_slot, to_slot)
    if not inv[from_side] then return 0 end
    local src = inv[from_side][from_slot]
    if not src or (src.size or 0) < 1 then return 0 end
    local max_to = inv_sizes[to_side] or 0
    if max_to < 1 then return 0 end
    local dest = to_slot
    if not dest then
      for i = 1, max_to do
        if not inv[to_side] or not inv[to_side][i] then
          dest = i
          break
        end
      end
    end
    if not dest or dest < 1 or dest > max_to then return 0 end
    inv[to_side] = inv[to_side] or {}
    if inv[to_side][dest] then return 0 end

    inv[to_side][dest] = { name = src.name, damage = src.damage, size = 1 }
    inv[from_side][from_slot] = nil
    return 1
  end
  return tp
end

local function make_fixture(f)
  local now = 0
  local tp = new_transposer(f.inv_sizes, f.items)
  local adapter = nil
  if f.adapter then
    adapter = {
      getInventorySize = function(side)
        if side ~= f.adapter.side then return 0 end
        return 3
      end,
      getStackInSlot = function(side, slot)
        if side ~= f.adapter.side then return nil end
        if slot ~= 1 then return nil end
        if f.adapter.has_items then return stack(14) end
        return nil
      end,
    }
  end
  local scan_calls = { transposer_inventory = 0 }
  local original_get_inv_size = tp.getInventorySize
  tp.getInventorySize = function(side)
    scan_calls.transposer_inventory = scan_calls.transposer_inventory + 1
    return original_get_inv_size(side)
  end
  local component = {
    proxy = function(address)
      if address == "tp-1" then return tp end
      if address == "adapter-1" and adapter then return adapter end
      if address == "db-1" then return {} end
      if address == "gt-1" then return {} end
      error("unknown proxy " .. tostring(address))
    end,
    list = function()
      local out = {
        ["tp-1"] = "transposer",
        ["db-1"] = "database",
        ["gt-1"] = "gt_machine",
      }
      if adapter then out["adapter-1"] = "adapter" end
      return out
    end,
  }
  local cfg = {
    circuit_item_name = "gregtech:gt.integrated_circuit",
    staging_timeout_s = 3,
    monitor_poll_s = 0.15,
    database_address = "db-1",
    machines = {
      {
        id = "machine_01",
        gt_address = "gt-1",
        transposer_address = "tp-1",
        side_buffer = 3,
        side_bus_b = 4,
        side_return = 3,
        buffer_adapter_address = f.adapter and "adapter-1" or nil,
        buffer_adapter_side = f.adapter and f.adapter.side or nil,
        input_slot = 1,
      },
    },
  }
  local manager = CircuitManager.new({ config = cfg, component = component })
  local loop = CircuitLoop.new({
    config = cfg,
    component = component,
    circuit_manager = manager,
    now = function() return now end,
    log = function() end,
  })
  local machine = cfg.machines[1]
  return {
    tp = tp,
    loop = loop,
    machine = machine,
    scans = scan_calls,
    advance = function(s) now = now + s end,
  }
end

io.write("\n" .. bold("AutoOS Circuit Loop Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- idle -> staging -> monitoring -------------------------------------------------
do
  local fx = make_fixture({
    inv_sizes = { [3] = 3, [4] = 3 },
    items = { [3] = { [1] = stack(18) }, [4] = {} },
  })
  local fast1 = fx.loop:tick_lane(fx.machine, { available = true, active = false })
  local fast2 = fx.loop:tick_lane(fx.machine, { available = true, active = false })
  local dbg = fx.loop:get_lane_debug("machine_01")
  check("idle transitions into active loop", fast1 == true)
  check("staging moves one circuit to bus", fast2 == true and fx.tp.getStackInSlot(4, 1) ~= nil)
  check("staging enters monitoring", dbg.state == "monitoring", dbg.state)
end

-- monitoring waits for active true then false ----------------------------------
do
  local fx = make_fixture({
    inv_sizes = { [3] = 3, [4] = 3 },
    items = { [3] = { [1] = stack(18) }, [4] = {} },
  })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  fx.loop:tick_lane(fx.machine, { available = true, active = true })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  local _, events = fx.loop:tick_lane(fx.machine, { available = true, active = false })
  local recovered = false
  for _, ev in ipairs(events) do
    if ev.type == "recover_ok" then recovered = true end
  end
  check("monitoring waits for active true then false", recovered)
end

-- timeout evacuation ------------------------------------------------------------
do
  local fx = make_fixture({
    inv_sizes = { [3] = 3, [4] = 3 },
    items = { [3] = { [1] = stack(18) }, [4] = {} },
  })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  fx.advance(3.2)
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  local _, events = fx.loop:tick_lane(fx.machine, { available = true, active = false })
  local recovered = false
  for _, ev in ipairs(events) do
    if ev.type == "recover_ok" then recovered = true end
  end
  check("timeout evacuates when machine never starts", recovered)
end

-- extraction returns to buffer side --------------------------------------------
do
  local fx = make_fixture({
    inv_sizes = { [3] = 3, [4] = 3 },
    items = { [3] = { [1] = stack(18) }, [4] = {} },
  })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  fx.loop:tick_lane(fx.machine, { available = true, active = true })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  check("extraction returns circuit to buffer", fx.tp.getStackInSlot(3, 1) ~= nil)
end

-- bus occupied prevents duplicate staging --------------------------------------
do
  local fx = make_fixture({
    inv_sizes = { [3] = 3, [4] = 3 },
    items = { [3] = { [1] = stack(18) }, [4] = { [1] = stack(14) } },
  })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  fx.loop:tick_lane(fx.machine, { available = true, active = false })
  local on_buffer = fx.tp.getStackInSlot(3, 1)
  check("occupied bus blocks duplicate stage", on_buffer ~= nil)
end

-- adapter gate: empty adapter avoids transposer scan ---------------------------
do
  local fx = make_fixture({
    inv_sizes = { [3] = 3, [4] = 3 },
    items = { [3] = { [1] = stack(18) }, [4] = {} },
    adapter = { side = 1, has_items = false },
  })
  local fast = fx.loop:tick_lane(fx.machine, { available = true, active = false })
  local dbg = fx.loop:get_lane_debug("machine_01")
  check("adapter-empty stays idle", fast == false and dbg.state == "idle")
  check("adapter-empty skips transposer inventory scan", fx.scans.transposer_inventory == 0, fx.scans.transposer_inventory)
end

-- adapter fallback: proxy fail still uses transposer scan -----------------------
do
  local fx = make_fixture({
    inv_sizes = { [3] = 3, [4] = 3 },
    items = { [3] = { [1] = stack(18) }, [4] = {} },
    adapter = nil,
  })
  fx.machine.buffer_adapter_address = "missing-adapter"
  fx.machine.buffer_adapter_side = 1
  local fast = fx.loop:tick_lane(fx.machine, { available = true, active = false })
  local dbg = fx.loop:get_lane_debug("machine_01")
  check("missing adapter falls back to transposer", fast == true and dbg.state == "staging", dbg.state)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Circuit loop result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
