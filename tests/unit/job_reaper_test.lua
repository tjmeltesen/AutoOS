#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/job_reaper_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  package.path,
}, ";")

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

io.write("\n" .. bold("JobReaper Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local jobs = {
    JobDescriptor.create({}, "central", "job_001"),
  }
  jobs[1].status = "done"
  JobReaper.reap(jobs, 2)
  check("done jobs are removed", #jobs == 0)
end

do
  local jobs = {
    JobDescriptor.create({}, "central", "job_001"),
  }
  jobs[1].status = "failed"
  JobReaper.reap(jobs, 2)
  check("failed with remaining attempts is requeued", jobs[1].status == "pending")
  check("failed requeue increments attempt", jobs[1].attempt == 2)
  check("failed requeue clears machine_id", jobs[1].machine_id == nil)
  check("failed requeue clears started_at", jobs[1].started_at == nil)
end

do
  local jobs = {
    JobDescriptor.create({}, "central", "job_001"),
  }
  jobs[1].status = "failed"
  jobs[1].attempt = 3
  JobReaper.reap(jobs, 2)
  check("failed with exhausted attempts becomes dead and removed", #jobs == 0)
end

do
  local jobs = {
    JobDescriptor.create({}, "central", "job_001"),
  }
  jobs[1].status = "dead"
  JobReaper.reap(jobs, 2)
  check("dead jobs are removed", #jobs == 0)
end

do
  local jobs = {
    JobDescriptor.create({}, "central", "job_001"),
    JobDescriptor.create({}, "central", "job_002"),
  }
  jobs[1].status = "pending"
  jobs[2].status = "done"
  JobReaper.reap(jobs, 2)
  check("pending jobs are untouched by reaping", #jobs == 1 and jobs[1].status == "pending")
end

do
  local jobs = {
    JobDescriptor.create({}, "central", "job_001"),
    JobDescriptor.create({}, "central", "job_002"),
  }
  jobs[1].status = "running"
  jobs[2].status = "done"
  JobReaper.reap(jobs, 2)
  check("running jobs survive reaping", #jobs == 1 and jobs[1].status == "running")
end

do
  -- Multiple reapable jobs in one pass (reverse iteration)
  local jobs = {}
  for i = 1, 5 do
    jobs[i] = JobDescriptor.create({}, "central", "job_" .. string.format("%03d", i))
  end
  jobs[1].status = "done"
  jobs[2].status = "done"
  jobs[3].status = "dead"
  jobs[4].status = "pending"
  jobs[5].status = "running"
  JobReaper.reap(jobs, 2)
  check("multi-reap leaves pending+running only", #jobs == 2)
  check("multi-reap preserves pending", jobs[1].status == "pending")
  check("multi-reap preserves running", jobs[2].status == "running")
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("JobReaper result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
