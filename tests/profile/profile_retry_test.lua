#!/usr/bin/env lua
-- Profile: retry cost as failure rate increases.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/profile/profile_retry_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  package.path,
}, ";")

local ProfileHarness = require("profile_harness")
local JobDescriptor = require("job_descriptor")
local JobReaper = require("job_reaper")

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

io.write("\n" .. bold("Profile: Retry Cost Curve") .. "\n")
io.write(string.rep("-", 60) .. "\n")

local profiler = ProfileHarness.new({ iterations = 200 })

-- Profile job lifecycle at different failure rates
local function benchmark_at_rate(failure_rate)
  local jobs = {}
  for i = 1, 50 do
    jobs[i] = JobDescriptor.create({}, "central", "job_" .. i, i * 10)
    -- Apply failure rate: mark some as failed
    if math.random() < failure_rate then
      jobs[i].status = "failed"
      jobs[i].attempt = 1
    end
  end
  JobReaper.reap(jobs, 3)
end

profiler:measure("retry_0pct", function() benchmark_at_rate(0.0) end)
profiler:measure("retry_20pct", function() benchmark_at_rate(0.2) end)
profiler:measure("retry_50pct", function() benchmark_at_rate(0.5) end)
profiler:measure("retry_80pct", function() benchmark_at_rate(0.8) end)

check("0% rate measured", profiler.results.retry_0pct ~= nil)
check("80% rate measured", profiler.results.retry_80pct ~= nil)
check("80% cost is acceptable",
  profiler.results.retry_80pct.mean < profiler.results.retry_0pct.mean * 5,
  string.format("0%:%.3fms 80%:%.3fms",
    profiler.results.retry_0pct.mean * 1000,
    profiler.results.retry_80pct.mean * 1000))

-- Save report
local report_dir = here .. sep .. "reports"
os.execute('mkdir "' .. report_dir .. '" 2>NUL')
profiler:save_report(report_dir .. sep .. "profile_retry.csv")
print("\n" .. profiler:report())

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Profile retry result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
