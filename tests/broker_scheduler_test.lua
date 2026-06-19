#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/broker_scheduler_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local Scheduler = require("coroutine_scheduler")
local BrokerMain = require("broker_main")
local Protocols = require("network_protocols")
local unpack = table.unpack or unpack

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

io.write("\n" .. bold("AutoOS Broker Scheduler Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local now = 0
  local event_q = {
    { "modem_message", "local", "orch", 106, 1, Protocols.trigger_craft("sub", "x") },
    { "component_unavailable", "gt_machine", "gt-1" },
  }
  local event = {
    pull = function(timeout)
      if #event_q > 0 then return unpack(table.remove(event_q, 1)) end
      if timeout then now = now + timeout end
      return nil
    end,
  }
  local scheduler = Scheduler.new({
    event = event,
    computer = { uptime = function() return now end },
    log = function() end,
  })
  local lane_steps = 0
  local stale = false
  local ctx = {
    scheduler = scheduler,
    state = { poll_results = {}, dirty = {}, events = {} },
    config = {
      subnet_id = "sub",
      tick_interval = 0.1,
      monitor_poll_s = 0.01,
      machines = { { id = "machine_01" } },
    },
    poll = {
      poll_machine = function(_, machine)
        return { id = machine.id, available = true, healthy = true, active = false, has_work = false }
      end,
      mark_proxy_cache_stale = function() stale = true end,
    },
    watch = {
      any_fast_tick = function() return lane_steps < 3 end,
      step_central = function() end,
      step_heartbeat = function() end,
      step_lane = function()
        lane_steps = lane_steps + 1
      end,
    },
    lane_dispatch = {
      get_lane_debug = function()
        return { state = lane_steps < 3 and "transfer" or "idle" }
      end,
    },
  }

  BrokerMain.attach_tasks(ctx)
  scheduler:run(16)

  local saw_modem = false
  for _, ev in ipairs(ctx.state.events) do
    if ev.type == "modem_message" and ev.from == "orch" then saw_modem = true end
  end
  check("modem event processed while lanes active", saw_modem and lane_steps > 0)
  check("active lane consumes multiple slices per wake", lane_steps >= 3)
  check("component event marks poll cache stale", stale == true)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Broker scheduler result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
