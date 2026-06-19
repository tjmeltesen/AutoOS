#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/lane_coroutine_test.lua"
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

io.write("\n" .. bold("AutoOS Lane Coroutine Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local sleep_calls, yield_calls, attempts = 0, 0, 0
  local inv = { [1] = { [1] = { name = "x", size = 1 } }, [4] = {} }
  local item_tp = {
    getInventorySize = function(side) return side == 1 and 4 or 4 end,
    getStackInSlot = function(side, slot) return inv[side] and inv[side][slot] end,
    getSlotStackSize = function(side, slot)
      local st = inv[side] and inv[side][slot]
      return st and st.size or 0
    end,
    transferItem = function(from_side, to_side, count, from_slot)
      attempts = attempts + 1
      if attempts <= 4 then return 0 end
      inv[to_side][1] = inv[from_side][from_slot]
      inv[from_side][from_slot] = nil
      return 1
    end,
  }
  local cfg = {
    input_mode = "per_lane",
    circuit_item_name = "gregtech:gt.integrated_circuit",
    circuit_bus_slot = 1,
    machines = {},
  }
  local component = { proxy = function() return item_tp end, list = function() return {} end }
  local dispatch = LaneDispatch.new({
    config = cfg,
    component = component,
    circuit_manager = CircuitManager.new({ config = cfg, component = component }),
    now = function() return 0 end,
    log = function() end,
    yield_now = function() yield_calls = yield_calls + 1 end,
    yield_sleep = function(seconds)
      if seconds ~= 0.05 then error("unexpected sleep") end
      sleep_calls = sleep_calls + 1
    end,
  })
  local machine = { id = "m", side_buffer = 1, side_bus_b = 4, chest_slot_start = 1 }
  local lane = { transfer_item_slot = nil, transfer_item_retry = 1 }

  local moved1, pending1 = dispatch:_transfer_items(item_tp, machine, lane)
  local slot_after_first = lane.transfer_item_slot
  local moved2, pending2 = dispatch:_transfer_items(item_tp, machine, lane)
  local moved3, pending3 = dispatch:_transfer_items(item_tp, machine, lane)

  check("retry yields instead of blocking sleep", sleep_calls >= 2 and yield_calls >= 1)
  check("item transfer cursor survives retry yields", slot_after_first == 1 and moved1 == false and pending1 == true)
  check("item transfer eventually clears cursor", (moved2 or moved3) and pending2 == true and pending3 == false and lane.transfer_item_slot == nil)
end

do
  local cfg = {
    input_mode = "central",
    database_address = "db-1",
    interface_fluid_side = 0,
    machines = {},
  }
  local component = { proxy = function() return {} end, list = function() return {} end }
  local dispatch = LaneDispatch.new({
    config = cfg,
    component = component,
    circuit_manager = CircuitManager.new({ config = cfg, component = component }),
    now = function() return 10 end,
    log = function() end,
  })
  local lane = dispatch:_lane("m1")
  lane.state = "settle"
  lane.job = { id = "job-crash", status = "running" }
  lane.job_id = "job-crash"
  lane.locked_resources = { "interface:if-1", "db:db-1" }
  dispatch._locks["interface:if-1"] = "m1"
  dispatch._locks["db:db-1"] = "m1"
  dispatch._tick_lane_impl = function() error("boom") end
  local fast, ev = dispatch:tick_lane({ id = "m1" }, { available = true, healthy = true })
  local dbg = dispatch:get_lane_debug("m1")
  check("lane crash faults and releases locks",
    fast == false
      and ev[1] and ev[1].type == "recover_failed"
      and dbg.state == "faulted"
      and dispatch._locks["interface:if-1"] == nil
      and dispatch._locks["db:db-1"] == nil)
end

do
  local cfg = {
    input_mode = "central",
    database_address = "db-1",
    interface_fluid_side = 0,
    machines = {},
  }
  local component = { proxy = function() return {} end, list = function() return {} end }
  local dispatch = LaneDispatch.new({
    config = cfg,
    component = component,
    circuit_manager = CircuitManager.new({ config = cfg, component = component }),
    now = function() return 0 end,
    log = function() end,
  })
  local resources = dispatch:_job_resources({
    id = "m1",
    interface_address = "if-1",
    item_transposer_address = "item-1",
    fluid_transposer_address = "fluid-1",
  }, { id = "job-1" })
  local has_db = false
  for _, res in ipairs(resources) do
    if res == "db:db-1" then has_db = true end
  end
  check("database is not held as lane-long job lock", has_db == false)
end

do
  local cfg = {
    input_mode = "central",
    database_address = "db-1",
    interface_fluid_side = 0,
    machines = {},
  }
  local component = { proxy = function() return {} end, list = function() return {} end }
  local dispatch = LaneDispatch.new({
    config = cfg,
    component = component,
    circuit_manager = CircuitManager.new({ config = cfg, component = component }),
    now = function() return 0 end,
    log = function() end,
  })
  local lane = dispatch:_lane("m1")
  lane.state = "queue"
  lane.locked_resources = { "interface:if-1" }
  dispatch._locks["interface:if-1"] = "m1"
  dispatch:_transition("m1", lane, "wait_complete", "queue done")
  check("staging locks release while machine keeps running",
    lane.state == "wait_complete"
      and #lane.locked_resources == 0
      and dispatch._locks["interface:if-1"] == nil)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Lane coroutine result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
