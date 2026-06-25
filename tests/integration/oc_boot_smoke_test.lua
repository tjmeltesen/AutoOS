#!/usr/bin/env lua
-- OC boot smoke: verify entry point modules load without crashing.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/integration/oc_boot_smoke_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "tasks" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "orchestrator" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "shared" .. sep .. "?.lua",
  package.path,
}, ";")

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

io.write("\n" .. bold("OC Boot Smoke Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- Core modules that don't need OC hardware
local modules = {
  "config",
  "coroutine_scheduler",
  "lane_state",
  "lock_manager",
  "job_descriptor",
  "job_manifest",
  "buffer_monitor",
  "admission_control",
  "job_reaper",
  "watchdog",
  "completion_detector",
  "job_assigner",
  "job_factory",
  "machine_selector",
  "lane_context",
  "lane_sides",
  "lane_worker",
  "lane_stocking",
  "lane_completion",
  "lane_extraction",
  "maintenance_parse",
  "fluid_tanks",
  "circuit_manager",
  "fault_net",
  "dispatch_clock",
  "task_registry",
  "logger",
  "broker_event_bus",
  "broker_poll_cache",
  "broker_registry_adapter",
  "descriptor_cache",
  "network_protocols",
  "rob_tick",
  "rob_dispatcher",
  "constants",
}

for _, mod in ipairs(modules) do
  local ok, result = pcall(require, mod)
  check("require " .. mod, ok and type(result) == "table", ok and "" or tostring(result))
end

-- Orchestrator modules
local orch_modules = {
  "orchestrator_config",
  "orchestrator",
}

for _, mod in ipairs(orch_modules) do
  local ok, result = pcall(require, mod)
  check("require " .. mod, ok and type(result) == "table", ok and "" or tostring(result))
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("OC boot smoke result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
