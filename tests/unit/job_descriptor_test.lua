#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/job_descriptor_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  package.path,
}, ";")

local JobDescriptor = require("job_descriptor")

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

io.write("\n" .. bold("JobDescriptor Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local manifest = { recipe_uid = 42, recipe_key = "item:ingotIron" }
  local job = JobDescriptor.create(manifest, "central", "job_001", 1000)
  check("create sets id", job.id == "job_001")
  check("create sets source", job.source == "central")
  check("create sets status pending", job.status == "pending")
  check("create stores manifest", job.manifest.recipe_uid == 42)
  check("create sets attempt 1", job.attempt == 1)
  check("create sets created_at", job.created_at == 1000)
  check("create has nil machine_id", job.machine_id == nil)
  check("create has nil started_at", job.started_at == nil)
  check("create has nil last_error", job.last_error == nil)
end

do
  local pending_jobs = {
    JobDescriptor.create({}, "central", "job_001"),
    JobDescriptor.create({}, "central", "job_002"),
  }
  local ok = JobDescriptor.set_status(pending_jobs, "job_001", "running")
  check("set_status returns true on found", ok)
  check("set_status updates status", pending_jobs[1].status == "running")
  check("set_status does not touch other job", pending_jobs[2].status == "pending")
end

do
  local pending_jobs = { JobDescriptor.create({}, "central", "job_001") }
  local ok = JobDescriptor.set_status(pending_jobs, "nonexistent", "done")
  check("set_status returns false on missing", ok == false)
  check("set_status does not mutate on missing", pending_jobs[1].status == "pending")
end

do
  local job = JobDescriptor.create({}, "central", "job_001")
  check("is_retryable true at attempt 1 with max 2", JobDescriptor.is_retryable(job, 2))
  job.attempt = 2
  check("is_retryable false at attempt 2 (equal max)", not JobDescriptor.is_retryable(job, 2))
  job.attempt = 3
  check("is_retryable false at attempt 3 with max 2",
    not JobDescriptor.is_retryable(job, 2))
  job.attempt = 1
  check("is_retryable uses default max 2 when nil",
    JobDescriptor.is_retryable(job, nil) == true)
end

do
  local job = JobDescriptor.create({}, "central", "job_001")
  check("is_terminal false for pending", not JobDescriptor.is_terminal(job))
  job.status = "done"
  check("is_terminal true for done", JobDescriptor.is_terminal(job))
  job.status = "dead"
  check("is_terminal true for dead", JobDescriptor.is_terminal(job))
  job.status = "running"
  check("is_terminal false for running", not JobDescriptor.is_terminal(job))
  job.status = "failed"
  check("is_terminal false for failed", not JobDescriptor.is_terminal(job))
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("JobDescriptor result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
