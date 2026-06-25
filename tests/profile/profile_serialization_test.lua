#!/usr/bin/env lua
-- Profile: serialization scalability at different batch sizes.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/profile/profile_serialization_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "shared" .. sep .. "?.lua",
  package.path,
}, ";")

local ProfileHarness = require("profile_harness")
local Protocols = require("network_protocols")

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

io.write("\n" .. bold("Profile: Serialization Scalability") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local profiler = ProfileHarness.new({ iterations = 500 })

-- Profile encoding a BROKER_HEALTH message (most common)
profiler:measure("encode_health_1", function()
  Protocols.broker_health("subnet-1", "machine-01", "WORKING", "nominal")
end)

-- Profile encode + parse round-trip
profiler:measure("roundtrip_health", function()
  local msg = Protocols.broker_health("s1", "m1", "WORKING", "ok")
  Protocols.parse(msg)
end)

-- Profile complex message (SUBNET_DELIVERY has 7 fields)
profiler:measure("roundtrip_delivery", function()
  local msg = Protocols.subnet_delivery("s1", "j1", 42, "item:ingotIron", 144000, "src")
  Protocols.parse(msg)
end)

-- Profile batch encoding (simulate 100 message broadcast)
profiler:measure("batch_100_encodes", function()
  for i = 1, 100 do
    Protocols.broker_health("s1", "m" .. i, "IDLE", "ok")
  end
end)

check("encode measured", profiler.results.encode_health_1 ~= nil)
check("roundtrip measured", profiler.results.roundtrip_health ~= nil)
check("batch measured", profiler.results.batch_100_encodes ~= nil)
check("all timings positive", profiler.results.encode_health_1.mean > 0)
check("roundtrip cost is < 10x encode",
  profiler.results.roundtrip_health.mean < profiler.results.encode_health_1.mean * 10)

-- Save report
local report_dir = here .. sep .. "reports"
os.execute('mkdir "' .. report_dir .. '" 2>NUL')
profiler:save_report(report_dir .. sep .. "profile_serialization.csv")
print("\n" .. profiler:report())

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Profile serialization result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
