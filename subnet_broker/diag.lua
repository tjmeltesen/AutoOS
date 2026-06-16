--[[
  AutoOS Subnet Broker — in-game diagnostic (Array Watch topology)

  Run from OC shell:
    loadfile("/home/subnet_broker/diag.lua")()

  Transposer wiring probe (which face touches bus / ME):
    loadfile("/home/subnet_broker/probe_transposer.lua")()
    loadfile("/home/subnet_broker/probe_transposer.lua")("machine_01")

  Checks, in order:
    1. Config validation
    2. Every configured UUID is on the OC network with the right type
    3. Fluid drops visible per lane ("drop of ..." items need a Fluid Discretizer)
    4. Maintenance poll per lane
    5. Load balancer math scenarios

  Optional live lane test (edit flags below, re-run):
    CIRCUIT_TEST_LANE = "machine_01"
    CIRCUIT_TEST_RECOVER = true   -- sweep circuit back after push+fluid

  REPL recover (after probe_transposer sets sides):
    package.loaded["circuit_manager"] = nil
    local C = require("circuit_manager").new({ config = require("config"), component = require("component") })
    local ok, err = C:recover_circuit("machine_01", nil)
    print("recover", ok, err or "")

  Fluid probe (mB visible per transposer face):
    local F = require("demoted.fluid_lane")
    local tp = require("component").proxy(require("config").machines[1].transposer_address)
    print(F.transposer_tank_summary(tp))

  Descriptor cache state (which db slot holds which circuit/fluid):
    local D = require("descriptor_cache").new({ config = require("config"), component = require("component") })
    -- after a lane test on the same D instance:
    for k, e in pairs(D:debug_dump()) do print(k, "slot", e.slot, "last_used", e.last_used) end
]]

local CIRCUIT_TEST_LANE = nil
local CIRCUIT_TEST_RECIPE = "polyethylene"
local CIRCUIT_TEST_VOLUME = 1000
local CIRCUIT_TEST_RECOVER = false

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("config")
local LoadBalancer = require("demoted.load_balancer")
local interface_mode = Config.interface_mode or "transposer"

local function recover_interface_address(machine_row)
  if interface_mode == "transposer" then
    return nil
  end
  if interface_mode == "shared" then
    return Config.shared_interface_address
  end
  return machine_row.interface_address
end

local all_pass = true
local warn = false

local function fail(msg)
  all_pass = false
  print("[AutoOS] FAIL: " .. msg)
end

-- 1. Config validation -------------------------------------------------------
local ok, err = Config.validate(Config)
if ok then
  print("[AutoOS] Config validate: OK")
else
  fail("Config validate: " .. tostring(err))
end

-- 2. UUID walk ----------------------------------------------------------------
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
    local iface_addr = recover_interface_address(m)
    if iface_addr and iface_addr ~= "" then
      print(string.format("[AutoOS] %s recover_interface (optional OC) %s %s",
        m.id, tostring(iface_addr), type_label(component_addrs[iface_addr])))
    else
      print(string.format("[AutoOS] %s recover: transposer-only (no OC me_interface)", m.id))
    end
    print(string.format("[AutoOS] %s transposer_address %s %s",
      m.id, m.transposer_address, type_label(component_addrs[m.transposer_address])))
  end
  print(string.format("[AutoOS] database %s %s",
    Config.database_address, type_label(component_addrs[Config.database_address])))
else
  print("[AutoOS] component.list unavailable — skipping UUID walk")
end

-- 2b. Database slot occupancy (read-only scan — diag never writes descriptors) --
if component_api and Config.database_address then
  pcall(function()
    local db = component_api.proxy(Config.database_address)
    if not db or not db.get then return end
    local count = Config.database_slot_count or 25
    local used = 0
    print("[AutoOS] database slot scan (read-only):")
    for slot = 1, count do
      local ok_get, entry = pcall(db.get, slot)
      if ok_get and type(entry) == "table" then
        used = used + 1
        if used <= 12 then
          local label = entry.label and (" label=" .. entry.label) or ""
          print(string.format("[AutoOS]   slot %d: %s damage %s%s",
            slot, tostring(entry.name), tostring(entry.damage), label))
        end
      end
    end
    if used == 0 then
      print("[AutoOS]   (empty — broker will allocate on first batch)")
    else
      print(string.format("[AutoOS] database slots used: %d / %d (from prior batch runs, not diag)", used, count))
    end
  end)
end

-- 3. Fluid drop visibility (Fluid Discretizer check) --------------------------
if component_api then
  pcall(function()
    local m = Config.machines[1]
    local iface = component_api.proxy(recover_interface_address(m))
    if iface and iface.getItemsInNetwork then
      local drops = iface.getItemsInNetwork({ name = "ae2fc:fluid_drop" })
      local n = type(drops) == "table" and #drops or 0
      if n > 0 then
        print(string.format("[AutoOS] Fluid drops visible in subnet ME: %d kinds", n))
        for i = 1, math.min(n, 6) do
          print(string.format("[AutoOS]   %s", tostring(drops[i].label)))
        end
      else
        warn = true
        print("[AutoOS] WARNING: no 'ae2fc:fluid_drop' items in subnet ME — fluid stocking needs a Fluid Discretizer on the subnet")
      end
    end
  end)
end

-- 4. Maintenance poll ---------------------------------------------------------
local healthy_count = 0
pcall(function()
  if not component_api then return end
  local MachinePoll = require("machine_poll")
  local poll = MachinePoll.new({ config = Config, component = component_api })
  local results = poll:poll_all()
  for _, m in ipairs(Config.machines) do
    local st = results[m.id]
    if not st or not st.available then
      warn = true
      print(string.format("[AutoOS] %s poll: UNAVAILABLE", m.id))
    elseif st.healthy then
      healthy_count = healthy_count + 1
      print(string.format("[AutoOS] %s poll: OK", m.id))
    else
      warn = true
      print(string.format("[AutoOS] %s poll: FAULT — %s", m.id, tostring(st.fault_message)))
    end
  end
  if healthy_count == 0 and next(component_addrs) then
    fail("all lanes faulted or unavailable")
  end
end)

-- 5. Load balancer scenarios ----------------------------------------------------
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
  if got == want then
    print(string.format("[AutoOS] %s: %dL / %dL → ops %s  PASS", name, volume, unit, got))
  else
    fail(name .. ": expected " .. want .. " got " .. got)
  end
end

check_scenario("Scenario A", 15000, 1440, { 3, 3, 2, 2 })
check_scenario("Scenario B", 3000, 1000, { 1, 1, 1, 0 })

-- Optional live lane test -------------------------------------------------------
if CIRCUIT_TEST_LANE and component_api then
  print(string.format(
    "[AutoOS] CIRCUIT TEST lane=%s recipe=%s volume=%d recover=%s",
    CIRCUIT_TEST_LANE, CIRCUIT_TEST_RECIPE, CIRCUIT_TEST_VOLUME, tostring(CIRCUIT_TEST_RECOVER)))
  local ok_test, test_err = pcall(function()
    local BrokerCore = require("demoted.broker_core")
    local ok_lane, lane_err = BrokerCore.manual_lane_test(
      CIRCUIT_TEST_LANE,
      CIRCUIT_TEST_RECIPE,
      CIRCUIT_TEST_VOLUME,
      {
        component = component_api,
        execute_hardware = true,
        recover_circuits = CIRCUIT_TEST_RECOVER,
      }
    )
    if ok_lane then
      print("[AutoOS] CIRCUIT TEST: PASS")
    else
      fail("CIRCUIT TEST: " .. tostring(lane_err))
    end
  end)
  if not ok_test then
    fail("CIRCUIT TEST crash: " .. tostring(test_err))
  end
elseif CIRCUIT_TEST_LANE then
  print("[AutoOS] CIRCUIT TEST skipped — no component API")
end

-- Verdict -----------------------------------------------------------------------
if all_pass then
  if warn then
    print("[AutoOS] DIAG: PASS (warnings above)")
  else
    print("[AutoOS] DIAG: PASS")
  end
else
  print("[AutoOS] DIAG: FAIL")
end
