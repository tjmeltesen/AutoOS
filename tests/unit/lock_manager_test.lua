#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/lock_manager_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  package.path,
}, ";")

local LockManager = require("lock_manager")

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

io.write("\n" .. bold("LockManager Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local machine = {
    id = "machine_01",
    interface_address = "uuid-ae-iface",
    item_transposer_address = "uuid-item-tp",
    fluid_transposer_address = "uuid-fluid-tp",
  }
  local resources = LockManager.build_resources(machine, nil)
  check("build_resources generates correct keys", #resources == 3)
  check("build_resources includes interface: prefix",
    resources[1]:match("^interface:") ~= nil)
  check("build_resources includes tp: for item transposer",
    resources[2]:match("^tp:") ~= nil)
  check("build_resources includes tp: for fluid transposer",
    resources[3]:match("^tp:") ~= nil)
end

do
  local machine = {
    id = "machine_01",
    interface_address = nil,
    item_transposer_address = "uuid-item-tp",
  }
  local shared = "uuid-shared-iface"
  local resources = LockManager.build_resources(machine, shared)
  check("build_resources uses shared_interface when per-machine is nil",
    resources[1] == "interface:uuid-shared-iface")
end

do
  local lm = LockManager.new()
  local ok, err = lm:acquire("machine_01", { "interface:uuid-ae", "tp:uuid-tp" })
  check("acquire succeeds on unowned resources", ok, err)
  local locks = lm:get_locks()
  check("acquire writes lock entries", locks["interface:uuid-ae"] == "machine_01")
end

do
  local lm = LockManager.new()
  lm:acquire("machine_01", { "tp:uuid-tp" })
  local ok, err = lm:acquire("machine_02", { "tp:uuid-tp" })
  check("acquire fails on already-owned resource", ok == false, err)
end

do
  local lm = LockManager.new()
  lm:acquire("machine_01", { "interface:uuid-ae" })
  local ok, err = lm:acquire("machine_01", { "interface:uuid-ae", "tp:uuid-tp" })
  check("acquire succeeds when same machine re-acquires own locks", ok, err)
  local locks = lm:get_locks()
  check("re-acquire adds new locks", locks["tp:uuid-tp"] == "machine_01")
end

do
  local lm = LockManager.new()
  lm:acquire("machine_01", { "interface:uuid-ae", "tp:uuid-item" })
  local lane = { locked_resources = { "interface:uuid-ae", "tp:uuid-item" } }
  lm:release("machine_01", lane)
  local locks = lm:get_locks()
  check("release frees all resources", locks["interface:uuid-ae"] == nil and locks["tp:uuid-item"] == nil)
  check("release clears lane.locked_resources", #lane.locked_resources == 0)
end

do
  local lm = LockManager.new()
  lm:acquire("machine_01", { "interface:uuid-ae", "tp:uuid-item" })
  local lane = { locked_resources = { "interface:uuid-ae", "tp:uuid-item" } }
  lm:release_transport("machine_01", lane)
  local locks = lm:get_locks()
  check("release_transport frees tp: keys", locks["tp:uuid-item"] == nil)
  check("release_transport keeps interface: keys", locks["interface:uuid-ae"] == "machine_01")
  check("release_transport trims lane.locked_resources",
    #lane.locked_resources == 1 and lane.locked_resources[1] == "interface:uuid-ae")
end

do
  local lm = LockManager.new()
  lm:acquire("machine_01", { "res1" })
  lm:acquire("machine_02", { "res2" })
  lm:release_all({ { locked_resources = { "res1" } }, { locked_resources = { "res2" } } })
  local locks = lm:get_locks()
  check("release_all clears all locks", next(locks) == nil)
end

do
  -- Belt-and-suspenders: stale entries found by scan
  local lm = LockManager.new()
  -- Manually inject a stale lock (without lane tracking)
  lm._locks["orphaned_key"] = "machine_01"
  lm._locks["legit_key"] = "machine_01"
  -- Release via scan
  lm:release("machine_01", nil)
  local locks = lm:get_locks()
  check("release with nil lane still cleans via scan",
    locks["orphaned_key"] == nil and locks["legit_key"] == nil)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("LockManager result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
