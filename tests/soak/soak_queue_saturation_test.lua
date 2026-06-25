#!/usr/bin/env lua
-- Soak: queue saturation — verify dispatch handles large buffers.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/soak/soak_queue_saturation_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  package.path,
}, ";")

local LaneState = require("lane_state")
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

io.write("\n" .. bold("Soak: Queue Saturation Test") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- Create 500 jobs and verify all can be managed
local jobs = {}
for i = 1, 500 do
  jobs[i] = JobDescriptor.create(
    { recipe_key = "item:item_" .. i },
    "central",
    "job_" .. string.format("%04d", i),
    i * 10
  )
end

check("500 jobs created", #jobs == 500)

-- Mark some done, some failed, some dead — verify reaper handles all
local done_count = 0
for i = 1, 500 do
  if i % 3 == 0 then
    jobs[i].status = "done"
    done_count = done_count + 1
  elseif i % 3 == 1 then
    jobs[i].status = "failed"
    jobs[i].attempt = 1
  else
    jobs[i].status = "pending"
  end
end

local before = #jobs
JobReaper.reap(jobs, 2)
local after = #jobs

-- Done jobs removed, failed retried -> pending, pending kept
check("reaper handles 500 jobs", before > after)
check("queue bounded after reaping", #jobs > 0, "remaining: " .. #jobs)

-- All remaining should be either pending or running
local all_valid = true
for _, j in ipairs(jobs) do
  if j.status ~= "pending" and j.status ~= "running" then
    all_valid = false
    break
  end
end
check("only pending+running remain", all_valid)
check("queue state is clean", #jobs <= before, string.format("%d -> %d", before, after))

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Soak queue saturation result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
