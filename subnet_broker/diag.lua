--[[
  AutoOS Subnet Broker — in-game diagnostic (1:1:1 lane topology)

  Run from OC shell:
    loadfile("/home/AutoOS/subnet_broker/diag.lua")()

  Manual circuit + fluid lane test (edit flags below, re-run):
    CIRCUIT_TEST_LANE = "machine_01"
    CIRCUIT_TEST_RECOVER = true  -- sweep circuit back after push+fluid

  REPL one-liners:
    local B = require("broker_core")
    B.manual_lane_test("machine_01", "molten_soldering_alloy", 1440, { recover_circuit = true })
    local C = require("circuit_manager").new({ config = require("config"), component = require("component") })
    C:push_circuit("machine_01", 14)
    C:recover_circuit("machine_01", 14)

  Fluid side probe (find which transposer face has fluid):
    local F = require("fluid_lane")
    local tp = component.proxy(require("config").machines[1].transposer_address)
    for s = 0, 5 do print(s, F.fluid_mb_on_side(tp, s)) end
]]

-- Set to a machine id to run live push+fluid (+ optional recover) after smoke checks.
local CIRCUIT_TEST_LANE = nil
local CIRCUIT_TEST_RECIPE = "molten_soldering_alloy"
local CIRCUIT_TEST_VOLUME = 1440
local CIRCUIT_TEST_RECOVER = false

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/AutoOS/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("config")
local LoadBalancer = require("load_balancer")

local all_pass = true
local phase2_warn = false

local function fail(msg)
  all_pass = false
  print("[AutoOS] FAIL: " .. msg)
end

local ok, err = Config.validate(Config)
if ok then
  print("[AutoOS] Config validate: OK")
else
  print("[AutoOS] Config validate: " .. tostring(err))
  all_pass = false
end

local component_addrs = {}
local component_api
pcall(function()
  component_api = require("component")
  if component_api and component_api.list then
    for addr, name in component_api.list() do
      component_addrs[addr] = name
    end
  end
end)

local function type_label(ctype)
  if not ctype then return "MISSING" end
  return "FOUND " .. ctype
end

if component_api and next(component_addrs) then
  for _, m in ipairs(Config.machines) do
    print(string.format("[AutoOS] %s gt_address %s %s",
      m.id, m.gt_address, type_label(component_addrs[m.gt_address])))
    print(string.format("[AutoOS] %s interface_address %s %s",
      m.id, m.interface_address, type_label(component_addrs[m.interface_address])))
    print(string.format("[AutoOS] %s transposer_address %s %s",
      m.id, m.transposer_address, type_label(component_addrs[m.transposer_address])))
  end
  if Config.database_address then
    print(string.format("[AutoOS] database %s %s",
      Config.database_address, type_label(component_addrs[Config.database_address])))
  end
else
  print("[AutoOS] component.list unavailable — skipping UUID walk")
end

local healthy_count = 0
pcall(function()
  local MachinePoll = require("machine_poll")
  if not component_api then return end
  local poll = MachinePoll.new({ config = Config, component = component_api })
  local results = poll:poll_all()
  for _, m in ipairs(Config.machines) do
    local st = results[m.id]
    if not st or not st.available then
      phase2_warn = true
      print(string.format("[AutoOS] %s poll: UNAVAILABLE", m.id))
    elseif st.healthy then
      healthy_count = healthy_count + 1
      print(string.format("[AutoOS] %s poll: OK", m.id))
    else
      phase2_warn = true
      print(string.format("[AutoOS] %s poll: FAULT — %s", m.id, tostring(st.fault_message)))
    end
  end
  if healthy_count == 0 and next(component_addrs) then
    fail("all lanes faulted or unavailable")
  end
end)

local function check_scenario(name, volume, unit, expected)
  local map, map_err = LoadBalancer.calculate_distribution(Config.machines, volume, unit)
  if not map then
    fail(name .. ": " .. tostring(map_err))
    return
  end
  local list = {}
  for _, m in ipairs(Config.machines) do
    list[#list + 1] = map[m.id].operations
  end
  local got = table.concat(list, ",")
  local want = table.concat(expected, ",")
  local match = #list == #expected
  if match then
    for i, v in ipairs(expected) do
      if list[i] ~= v then match = false break end
    end
  end
  if match then
    print(string.format("[AutoOS] %s: %dL / %dL → ops %s  PASS", name, volume, unit, got))
  else
    fail(name .. ": expected " .. want .. " got " .. got)
  end
end

check_scenario("Scenario A", 15000, 1440, { 3, 3, 2, 2 })
check_scenario("Scenario B", 3000, 1000, { 1, 1, 1, 0 })

if CIRCUIT_TEST_LANE and component_api then
  print(string.format(
    "[AutoOS] CIRCUIT TEST lane=%s recipe=%s volume=%d recover=%s",
    CIRCUIT_TEST_LANE, CIRCUIT_TEST_RECIPE, CIRCUIT_TEST_VOLUME, tostring(CIRCUIT_TEST_RECOVER)))
  local ok_test, test_err = pcall(function()
    local BrokerCore = require("broker_core")
    local ok, err = BrokerCore.manual_lane_test(
      CIRCUIT_TEST_LANE,
      CIRCUIT_TEST_RECIPE,
      CIRCUIT_TEST_VOLUME,
      {
        component = component_api,
        execute_hardware = true,
        recover_circuit = CIRCUIT_TEST_RECOVER,
      }
    )
    if ok then
      print("[AutoOS] CIRCUIT TEST: PASS")
    else
      fail("CIRCUIT TEST: " .. tostring(err))
    end
  end)
  if not ok_test then
    fail("CIRCUIT TEST crash: " .. tostring(test_err))
  end
elseif CIRCUIT_TEST_LANE then
  print("[AutoOS] CIRCUIT TEST skipped — no component API")
end

if all_pass then
  print("[AutoOS] PHASE 1 IN-GAME: PASS")
  if phase2_warn then
    print("[AutoOS] PHASE 2 IN-GAME: PASS (warnings — see poll lines)")
  else
    print("[AutoOS] PHASE 2 IN-GAME: PASS")
  end
else
  print("[AutoOS] PHASE 1 IN-GAME: FAIL")
  print("[AutoOS] PHASE 2 IN-GAME: FAIL")
end
