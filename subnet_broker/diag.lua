--[[
  AutoOS Subnet Broker — Phase 1 in-game diagnostic (read-only)

  Confirms config validity, optional component UUID presence, and README math
  scenarios. Does not call setWorkAllowed, ME APIs, or transposers.

  Run from OC shell:
    loadfile("/home/AutoOS/subnet_broker/diag.lua")()
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/AutoOS/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("config")
local LoadBalancer = require("load_balancer")

local all_pass = true

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

-- 2. UUID walk (in-game only when component API exists)
local component_addrs = {}
local has_component = pcall(function()
  local component = require("component")
  if component and component.list then
    for addr, name in component.list() do
      component_addrs[addr] = name
    end
  end
end)

if has_component and next(component_addrs) then
  for _, m in ipairs(Config.machines) do
    for _, field in ipairs({ "gt_address", "bus_in", "hatch_fluid" }) do
      local addr = m[field]
      local ctype = component_addrs[addr]
      if ctype then
        print(string.format("[AutoOS] %s %s %s FOUND %s", m.id, field, addr, ctype))
      else
        print(string.format("[AutoOS] %s %s %s MISSING", m.id, field, addr))
      end
    end
  end
else
  print("[AutoOS] component.list unavailable — skipping UUID walk (desktop or no OC)")
end

-- 3. Math scenarios
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

-- 4. Summary
if all_pass then
  print("[AutoOS] PHASE 1 IN-GAME: PASS")
else
  print("[AutoOS] PHASE 1 IN-GAME: FAIL")
end
