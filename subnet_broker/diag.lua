--[[
  AutoOS Subnet Broker — in-game diagnostic (read-only + optional circuit test)

  Run from OC shell:
    loadfile("/home/AutoOS/subnet_broker/diag.lua")()

  Optional circuit round-trip (in-game):
    DRY_RUN_CIRCUIT = true before loadfile, or in REPL after:
    local cm = require("circuit_manager").new({ config = require("config"), component = require("component") })
    cm:push_circuit("reactor_01", 14); cm:recover_circuit("reactor_01")
]]
DRY_RUN_CIRCUIT = true
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

-- 1. Config validate
local ok, err = Config.validate(Config)
if ok then
  print("[AutoOS] Config validate: OK")
else
  print("[AutoOS] Config validate: " .. tostring(err))
  all_pass = false
end

-- 2. Component list
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
  if ctype == "me_exportbus" then return "FOUND me_exportbus" end
  if ctype == "transposer" then return "FOUND transposer" end
  if ctype == "gt_machine" then return "FOUND gt_machine" end
  if ctype == "aemultipart" or ctype == "tilechest" then
    return "FOUND " .. ctype .. " (fluid/item ME bus)"
  end
  return "FOUND " .. ctype
end

if component_api and next(component_addrs) then
  for _, m in ipairs(Config.machines) do
    print(string.format("[AutoOS] %s gt_address %s %s",
      m.id, m.gt_address, type_label(component_addrs[m.gt_address])))
    print(string.format("[AutoOS] %s bus_in %s %s",
      m.id, m.bus_in, type_label(component_addrs[m.bus_in])))
    print(string.format("[AutoOS] %s hatch_fluid %s %s",
      m.id, m.hatch_fluid, type_label(component_addrs[m.hatch_fluid])))
  end

  local vault = Config.circuit_vault and Config.circuit_vault.address or Config.circuit_vault_address
  if vault then
    print(string.format("[AutoOS] circuit_vault %s %s", vault, type_label(component_addrs[vault])))
  end
  if Config.database_address then
    print(string.format("[AutoOS] database %s %s",
      Config.database_address, type_label(component_addrs[Config.database_address])))
  end
else
  print("[AutoOS] component.list unavailable — skipping UUID walk (desktop or no OC)")
end

-- 3. Machine poll (Phase 2)
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
      print(string.format("[AutoOS] %s poll: UNAVAILABLE (no gt_machine proxy)", m.id))
    elseif st.healthy then
      healthy_count = healthy_count + 1
      print(string.format("[AutoOS] %s poll: OK (work_allowed=%s active=%s)",
        m.id, tostring(st.work_allowed), tostring(st.active)))
    else
      phase2_warn = true
      print(string.format("[AutoOS] %s poll: FAULT — %s", m.id, tostring(st.fault_message)))
    end
  end
  if healthy_count == 0 and next(component_addrs) then
    fail("all machines faulted or unavailable")
  end
end)

-- 4. Math scenarios (Phase 1)
local function ops_list(pool, volume, unit)
  local map, map_err = LoadBalancer.calculate_distribution(pool, volume, unit)
  if not map then
    return nil, map_err
  end
  local list = {}
  for _, m in ipairs(pool) do
    list[#list + 1] = map[m.id].operations
  end
  return list
end

local function check_scenario(name, volume, unit, expected)
  local list, map_err = ops_list(Config.machines, volume, unit)
  if not list then
    fail(name .. ": " .. tostring(map_err))
    print(string.format("[AutoOS] %s  FAIL (%s)", name, tostring(map_err)))
    return
  end

  local got = table.concat(list, ",")
  local want = table.concat(expected, ",")
  local match = #list == #expected
  if match then
    for i, v in ipairs(expected) do
      if list[i] ~= v then
        match = false
        break
      end
    end
  end

  if match then
    print(string.format("[AutoOS] %s: %dL / %dL → ops %s  PASS", name, volume, unit, got))
  else
    fail(name .. ": expected " .. want .. " got " .. got)
    print(string.format("[AutoOS] %s: %dL / %dL → ops %s  FAIL (want %s)", name, volume, unit, got, want))
  end
end

check_scenario("Scenario A", 15000, 1440, { 3, 3, 2, 2 })
check_scenario("Scenario B", 3000, 1000, { 1, 1, 1, 0 })

-- 5. Optional circuit dry-run
if DRY_RUN_CIRCUIT and component_api then
  pcall(function()
    local CircuitManager = require("circuit_manager")
    local cm = CircuitManager.new({ config = Config, component = component_api })
    local ok_push, err_push = cm:push_circuit("reactor_01", 14)
    print(string.format("[AutoOS] Circuit push reactor_01: %s %s",
      ok_push and "OK" or "FAIL", tostring(err_push or "")))
    local ok_rec, err_rec = cm:recover_circuit("reactor_01", 14)
    print(string.format("[AutoOS] Circuit recover reactor_01: %s %s",
      ok_rec and "OK" or "FAIL", tostring(err_rec or "")))
    if not ok_push or not ok_rec then
      phase2_warn = true
    end
  end)
end

-- 6. Summary
if all_pass then
  print("[AutoOS] PHASE 1 IN-GAME: PASS")
  if phase2_warn then
    print("[AutoOS] PHASE 2 IN-GAME: PASS (with warnings — check poll/circuit lines above)")
  else
    print("[AutoOS] PHASE 2 IN-GAME: PASS")
  end
else
  print("[AutoOS] PHASE 1 IN-GAME: FAIL")
  print("[AutoOS] PHASE 2 IN-GAME: FAIL")
end
