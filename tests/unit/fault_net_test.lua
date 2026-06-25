#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/fault_net_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local FaultNet = require("fault_net")

local ESC = string.char(27)
local function green(t) return ESC .. "[32m" .. t .. ESC .. "[0m" end
local function red(t) return ESC .. "[31m" .. t .. ESC .. "[0m" end
local function bold(t) return ESC .. "[1m" .. t .. ESC .. "[0m" end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write("  -  " .. tostring(detail)) end
  io.write("\n")
end

io.write("\n" .. bold("AutoOS Fault Net Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

---------------------------------------------------------------------------
-- capture
---------------------------------------------------------------------------
do
  local logs = {}
  local ctx = {
    log = function(msg) logs[#logs + 1] = msg end,
  }
  FaultNet.capture(ctx, "test.tag", "something broke", { port = 42 })

  check("capture logs a [FAULT] line", logs[1]:find("%[FAULT%]") ~= nil)
  check("capture includes tag", logs[1]:find("test%.tag") ~= nil)
  check("capture includes error", logs[1]:find("something broke") ~= nil)
  check("capture includes extra field", logs[1]:find("port=42") ~= nil)
end

do
  local logs = {}
  local ctx = { log = function(msg) logs[#logs + 1] = msg end }
  FaultNet.capture(ctx, "minimal")
  check("capture handles missing err", logs[1]:find("%(unknown%)") ~= nil)
  check("capture with no extras produces clean line", not logs[1]:find("port"))
end

do
  local logs = {}
  local ctx = { log = function(msg) logs[#logs + 1] = msg end }
  FaultNet.capture(ctx, "string_extra", "err", "just_a_string")
  check("capture handles string extra", logs[1]:find("just_a_string") ~= nil)
end

do
  local ring = {}
  local ctx = {
    log = function() end,
    faults = { items = ring, head = 1, count = 0, max = 3 },
  }
  FaultNet.capture(ctx, "ring.test", "ring error")
  check("ring buffer has one entry", ctx.faults.count == 1)
  check("ring entry has tag", ring[1].tag == "ring.test")
  check("ring entry has err", ring[1].err == "ring error")
  check("ring entry has ts", type(ring[1].ts) == "string")

  FaultNet.capture(ctx, "r2", "e2")
  FaultNet.capture(ctx, "r3", "e3")
  FaultNet.capture(ctx, "r4", "e4")  -- wraps
  check("ring wraps after max=3", ctx.faults.count == 3)
  check("oldest evicted (r2 now at idx 2)", ring[1].tag == "r4")
  check("head points to next slot", ctx.faults.head == 2)  -- 1->2->3->(wrap to 1)->2
end

---------------------------------------------------------------------------
-- guard
---------------------------------------------------------------------------
do
  local logs = {}
  local ctx = { log = function(msg) logs[#logs + 1] = msg end }

  local ok, result = FaultNet.guard(ctx, "success.tag", function(x, y)
    return x + y
  end, 2, 3)
  check("guard success returns true", ok == true)
  check("guard success returns result", result == 5)
  check("guard success does not log fault", #logs == 0)
end

do
  local logs = {}
  local ctx = { log = function(msg) logs[#logs + 1] = msg end }

  local ok, tb = FaultNet.guard(ctx, "crash.tag", function()
    error("intentional boom")
  end)
  check("guard error returns false", ok == false)
  check("guard error returns traceback string", type(tb) == "string" and tb:find("intentional boom"))
  check("guard error captures fault", #logs == 1 and logs[1]:find("%[FAULT%]"))
end

do
  local logs = {}
  local ctx = { log = function(msg) logs[#logs + 1] = msg end }

  local ok, result = FaultNet.guard(ctx, "no.args", function()
    return "works"
  end)
  check("guard handles zero-arg function", ok == true and result == "works")
end

---------------------------------------------------------------------------
-- bind
---------------------------------------------------------------------------
do
  local logs = {}
  local ctx = { log = function(msg) logs[#logs + 1] = msg end }
  local net = FaultNet.bind(ctx)

  local ok, result = net.guard("bound.guard", function()
    return "bound ok"
  end)
  check("bind guard success", ok and result == "bound ok")

  net.capture("bound.capture", "bound err")
  check("bind capture works", logs[1]:find("bound%.capture") and logs[1]:find("bound err"))
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Fault net result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
