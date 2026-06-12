--[[
  AutoOS Subnet Broker — full line test (all lanes, live hardware)

  Run from OC shell:
    loadfile("/home/subnet_broker/test.lua")()

  What it does:
    1. Config validate
    2. Maintenance poll — skip faulted lanes
    3. One operation per healthy lane (circuit push + fluid pump + optional recover)
    4. Optional full batch across healthy pool
    5. Descriptor cache + database slot summary

  Edit the flags below, then re-run.
]]

-- ============ EDIT THESE ======================================================
local RECIPE_KEY = "polyethylene"       -- or "molten_soldering_alloy"
local LANE_VOLUME = nil                 -- nil = one op (1000L ethylene / 1440L solder)
local RECOVER_CIRCUITS = true           -- sweep circuit back to subnet after each lane
local RUN_BATCH = true                  -- after per-lane tests, run process_batch
local BATCH_VOLUME = 3000               -- 3000L ethylene → 3 ops across healthy lanes
-- =============================================================================

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("config")
local BrokerCore = require("broker_core")
local MachinePoll = require("machine_poll")

local component_api = require("component")

local passed, failed = 0, 0

local function pass(name, detail)
  passed = passed + 1
  print("[AutoOS] PASS  " .. name .. (detail and (" — " .. detail) or ""))
end

local function fail(name, detail)
  failed = failed + 1
  print("[AutoOS] FAIL  " .. name .. (detail and (" — " .. tostring(detail)) or ""))
end

print("\n[AutoOS] ========== FULL LINE TEST ==========")
print(string.format("[AutoOS] recipe=%s recover=%s batch=%s",
  RECIPE_KEY, tostring(RECOVER_CIRCUITS), tostring(RUN_BATCH)))

-- Config -----------------------------------------------------------------------
local ok_cfg, cfg_err = Config.validate(Config)
if ok_cfg then
  pass("config validate")
else
  fail("config validate", cfg_err)
  print("[AutoOS] ABORT — fix config.lua")
  return
end

local rules = Config.constraints.recipe_baselines[RECIPE_KEY]
if not rules then
  fail("recipe baseline", "unknown key " .. tostring(RECIPE_KEY))
  return
end

local unit = rules.fluid_requirement
local volume = LANE_VOLUME or unit
local circuit = rules.circuit_damage

print(string.format("[AutoOS] per-lane: %dL (%d op) circuit=%s fluid=%s",
  volume, math.floor(volume / unit), tostring(circuit), tostring(rules.fluid_label)))

BrokerCore.reset_descriptor_cache()

-- Healthy pool -----------------------------------------------------------------
local poll = MachinePoll.new({ config = Config, component = component_api })
local poll_results = poll:poll_all()
local active = poll:build_active_pool(poll_results)

for _, m in ipairs(Config.machines) do
  local st = poll_results[m.id]
  if not st or not st.available then
    print(string.format("[AutoOS] %s SKIP — unavailable", m.id))
  elseif not st.healthy then
    print(string.format("[AutoOS] %s SKIP — fault: %s", m.id, tostring(st.fault_message)))
  else
    print(string.format("[AutoOS] %s READY", m.id))
  end
end

if #active == 0 then
  fail("healthy pool", "no lanes available")
  return
end

print(string.format("[AutoOS] %d healthy lane(s) for live test", #active))

-- Per-lane: circuit + fluid (+ recover) ----------------------------------------
print("\n[AutoOS] --- Per-lane tests ---")

for _, m in ipairs(active) do
  print(string.format("\n[AutoOS] >> Lane %s", m.id))
  local ok_lane, err_lane = BrokerCore.manual_lane_test(m.id, RECIPE_KEY, volume, {
    component = component_api,
    execute_hardware = true,
    recover_circuits = RECOVER_CIRCUITS,
  })
  if ok_lane then
    pass("lane " .. m.id)
  else
    fail("lane " .. m.id, err_lane)
  end
end

-- Full batch -------------------------------------------------------------------
if RUN_BATCH then
  print(string.format("\n[AutoOS] --- Batch test (%dL %s) ---", BATCH_VOLUME, RECIPE_KEY))
  local batch_ok, summary = BrokerCore.process_batch(RECIPE_KEY, BATCH_VOLUME, nil, {
    component = component_api,
    execute_hardware = true,
    recover_circuits = false,
  })
  if batch_ok then
    pass("process_batch", string.format("%d/%d lanes",
      summary.succeeded, summary.dispatched))
  else
    local detail = string.format("%d/%d succeeded", summary.succeeded, summary.dispatched)
    for id, r in pairs(summary.lanes or {}) do
      if not r.ok then
        detail = detail .. string.format("; %s: %s", id, tostring(r.err))
      end
    end
    fail("process_batch", detail)
  end
end

-- Descriptor cache + DB slots --------------------------------------------------
print("\n[AutoOS] --- Descriptor cache ---")
pcall(function()
  local dc = require("descriptor_cache").new({ config = Config, component = component_api })
  local dump = dc.debug_dump()
  local n = 0
  for key, e in pairs(dump) do
    n = n + 1
    print(string.format("[AutoOS]   %s → slot %d (last_used %d)", key, e.slot, e.last_used))
  end
  if n == 0 then
    print("[AutoOS]   (cache empty — batch may not have run yet)")
  end
end)

print("\n[AutoOS] --- Database slots ---")
pcall(function()
  local db = component_api.proxy(Config.database_address)
  if not db or not db.get then return end
  local count = Config.database_slot_count or 9
  local used = 0
  for slot = 1, count do
    local e = db.get(slot)
    if e then
      used = used + 1
      print(string.format("[AutoOS]   slot %d: %s damage %s%s",
        slot, tostring(e.name), tostring(e.damage),
        e.label and (" label=" .. e.label) or ""))
    end
  end
  print(string.format("[AutoOS]   used %d / %d", used, count))
end)

-- Verdict ----------------------------------------------------------------------
print(string.format("\n[AutoOS] ========== DONE: %d passed, %d failed ==========", passed, failed))
if failed > 0 then
  print("[AutoOS] Fix failures above before production batches.")
end
