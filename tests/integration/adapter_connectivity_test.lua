#!/usr/bin/env lua
-- Adapter connectivity: validates Config + Registry resolve all machine addresses.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/integration/adapter_connectivity_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  package.path,
}, ";")

local Config = require("config")
local MockHardware = require("mock_broker_hardware")

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

io.write("\n" .. bold("Adapter Connectivity Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  check("Config is valid", select(1, Config.validate(Config)), select(2, Config.validate(Config)))
  check("Config has machines", Config.machines ~= nil and #Config.machines > 0)
  check("Config has database_address", Config.database_address ~= nil)
  check("Config has subnet_id", Config.subnet_id ~= nil)
end

do
  local mock = MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  for _, m in ipairs(Config.machines) do
    check("machine " .. m.id .. " has gt_address", m.gt_address ~= nil)
    check("machine " .. m.id .. " has interface_address", m.interface_address ~= nil)
    check("machine " .. m.id .. " has item_transposer_address", m.item_transposer_address ~= nil)

    -- Component proxy resolution (gt_address is the GT machine UUID)
    local proxies = {}
    proxies.machine = mock.component.proxy(m.gt_address)
    proxies.iface = mock.component.proxy(m.interface_address)
    proxies.item_tp = mock.component.proxy(m.item_transposer_address)

    for ptype, proxy in pairs(proxies) do
      check("proxy " .. m.id .. " " .. ptype .. " resolves", proxy ~= nil, type(proxy))
    end
  end
end

do
  -- Validate mock component.list resolves all components
  local mock = MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local all = mock.component.list()
  check("component.list returns non-empty table", type(all) == "table" and next(all) ~= nil)

  local machine_count = 0
  for _, m in ipairs(Config.machines) do
    if all[m.gt_address] then machine_count = machine_count + 1 end
  end
  check("all machines in component.list", machine_count == #Config.machines)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Adapter connectivity result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
