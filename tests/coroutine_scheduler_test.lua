#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/coroutine_scheduler_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local Scheduler = require("coroutine_scheduler")
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

local function make_sched(events)
  local now = 0
  local q = events or {}
  local logs = {}
  local event = {
    pull = function(timeout)
      if #q > 0 then return unpack(table.remove(q, 1)) end
      if timeout then now = now + timeout end
      return nil
    end,
  }
  local computer = { uptime = function() return now end }
  local scheduler = Scheduler.new({
    event = event,
    computer = computer,
    log = function(msg) logs[#logs + 1] = msg end,
  })
  return scheduler, function() return now end, logs
end

io.write("\n" .. bold("AutoOS Coroutine Scheduler Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local scheduler, now = make_sched()
  local woke_at
  scheduler:spawn("timer", function()
    Scheduler.sleep(0.5)
    woke_at = now()
  end)
  scheduler:run(4)
  check("timer wakeup", woke_at == 0.5, tostring(woke_at))
end

do
  local scheduler = make_sched({ { "other" }, { "custom_event", 42 } })
  local got
  scheduler:spawn("event_waiter", function()
    local _, value = Scheduler.wait_event("custom_event")
    got = value
  end)
  scheduler:run(5)
  check("event delivery by name", got == 42)
end

do
  local scheduler, _, logs = make_sched()
  local survived = false
  scheduler:spawn("bad", function() error("boom") end)
  scheduler:spawn("good", function()
    Scheduler.yield_now()
    survived = true
  end)
  scheduler:run(4)
  check("task error isolation", survived, logs[#logs] or "no logs")
end

do
  local scheduler = make_sched()
  local n = 0
  scheduler:spawn("stateful", function()
    n = n + 1
    Scheduler.yield_now()
    n = n + 1
    Scheduler.yield_now()
    n = n + 1
  end)
  scheduler:run(5)
  check("state survives yields", n == 3, tostring(n))
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Coroutine scheduler result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
