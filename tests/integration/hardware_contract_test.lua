#!/usr/bin/env lua
-- Hardware contract: validates mock proxies match OC-GTNH API surface.

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/integration/hardware_contract_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  package.path,
}, ";")

local MockHardware = require("mock_broker_hardware")
local Config = require("config")

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

io.write("\n" .. bold("Hardware Contract Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- Validate mock provides required OC component API
do
  local mock = MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })
  check("mock component table exists", type(mock.component) == "table")
  check("mock component.list exists", type(mock.component.list) == "function")
  check("mock component.proxy exists", type(mock.component.proxy) == "function")
  check("mock stats table exists", type(mock.stats) == "table")
  check("mock network exists", type(mock.network) == "table")
end

-- Validate each machine gets required proxies
do
  local mock = MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  for _, m in ipairs(Config.machines) do
    local tp, err = mock.component.proxy(m.item_transposer_address)
    check("transposer proxy for " .. m.id, tp ~= nil, err)

    local iface, err2 = mock.component.proxy(m.interface_address)
    check("interface proxy for " .. m.id, iface ~= nil, err2)

    -- Per-machine test
    local machine = mock.network[m.id]
    if machine then
      check("machine lane has hw", type(machine) == "table")
      check("machine has transposer proxy", type(machine.transposer_item) == "table")
      check("machine has ME interface", type(machine.me_interface) == "table")
    end
  end
end

-- Validate transposer API surface matches OC-GTNH contract
do
  local mock = MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local m1 = Config.machines[1]
  local tp = mock.component.proxy(m1.item_transposer_address)
  check("transposer has getInventorySize", type(tp.getInventorySize) == "function")
  check("transposer has getStackInSlot", type(tp.getStackInSlot) == "function")
  check("transposer has transferItem", type(tp.transferItem) == "function")
  check("transposer has getTankCount", type(tp.getTankCount) == "function")
  check("transposer has getTankLevel", type(tp.getTankLevel) == "function")
  check("transposer has transferFluid", type(tp.transferFluid) == "function")
end

-- Validate GT machine proxy API surface
do
  local mock = MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local m1 = Config.machines[1]
  local machine = mock.component.proxy(m1.machine_address)
  if machine then
    check("machine has getSensorInformation", type(machine.getSensorInformation) == "function")
    check("machine has isWorkAllowed", type(machine.isWorkAllowed) == "function")
    check("machine has isMachineActive", type(machine.isMachineActive) == "function")
    check("machine has hasWork", type(machine.hasWork) == "function")
  end
end

-- Validate ME interface API surface
do
  local mock = MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local m1 = Config.machines[1]
  local iface = mock.component.proxy(m1.interface_address)
  if iface then
    check("iface has setInterfaceConfiguration", type(iface.setInterfaceConfiguration) == "function")
    check("iface has getItemsInNetwork", type(iface.getItemsInNetwork) == "function")
    check("iface has getFluidsInNetwork", type(iface.getFluidsInNetwork) == "function")
    check("iface has store", type(iface.store) == "function")
  end
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Hardware contract result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
