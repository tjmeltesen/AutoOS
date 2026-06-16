--[[
  AutoOS Subnet Broker — full line test (all lanes, live hardware)

  Run from OC shell:
    loadfile("/home/subnet_broker/test.lua")()

  What it does:
    1. Config validate
    2. Maintenance poll — skip faulted lanes
    3. One operation per healthy lane (circuit push + fluid pump + optional recover)
    4. Optional full batch across healthy pool
    5. Optional multi-recipe interleaved dispatch (process_multi)
    6. Descriptor cache + database slot summary

  Edit the flags below, then re-run.
]]

-- ============ EDIT THESE ======================================================
local RECIPE_KEY = "polyethylene"       -- or "molten_soldering_alloy"
local LANE_VOLUME = nil                 -- nil = one op (1000L ethylene / 1440L solder)
local RECOVER_CIRCUITS = true           -- sweep circuit back to subnet after each lane
local RUN_BATCH = false                 -- after per-lane tests, run process_batch
local BATCH_VOLUME = 3000               -- 3000L ethylene → 3 ops across healthy lanes

-- Multi-recipe: ethylene on lanes 1-2, molten solder on 3-4 (interleaved dispatch)
local RUN_MULTI = true
local MULTI_JOBS = {
  { recipe = "polyethylene", volume = 2000, lanes = { "machine_01", "machine_02" } },
  { recipe = "molten_soldering_alloy", volume = 2880, lanes = { "machine_03", "machine_04" } },
}
local MULTI_ONLY_IDLE = true            -- skip lanes that are active/has_work
-- =============================================================================

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

-- Re-run after wget without rebooting the OC computer.
package.loaded["config"] = nil
package.loaded["machine_poll"] = nil
package.loaded["broker_core"] = nil

local Config = require("config")
local BrokerCore = require("demoted.broker_core")
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
print(string.format("[AutoOS] recipe=%s recover=%s batch=%s multi=%s",
  RECIPE_KEY, tostring(RECOVER_CIRCUITS), tostring(RUN_BATCH), tostring(RUN_MULTI)))

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

local function lane_is_idle(st)
  if MachinePoll.is_idle then
    return MachinePoll.is_idle(st)
  end
  return st and st.available and st.healthy and not st.active and not st.has_work
end

local function build_idle_pool(poll, poll_results)
  if poll.build_idle_pool then
    return poll:build_idle_pool(poll_results)
  end
  local pool = {}
  for _, machine in ipairs(Config.machines) do
    if lane_is_idle(poll_results[machine.id]) then
      pool[#pool + 1] = machine
    end
  end
  return pool
end

-- Healthy pool -----------------------------------------------------------------
local poll = MachinePoll.new({ config = Config, component = component_api })
if not poll.build_idle_pool and not MachinePoll.is_idle then
  print("[AutoOS] WARN  stale machine_poll.lua — wget latest machine_poll.lua + broker_core.lua")
end
local poll_results = poll:poll_all()
local active = poll:build_active_pool(poll_results)
local idle = build_idle_pool(poll, poll_results)

for _, m in ipairs(Config.machines) do
  local st = poll_results[m.id]
  if not st or not st.available then
    print(string.format("[AutoOS] %s SKIP — unavailable", m.id))
  elseif not st.healthy then
    print(string.format("[AutoOS] %s SKIP — fault: %s", m.id, tostring(st.fault_message)))
  elseif not lane_is_idle(st) then
    print(string.format("[AutoOS] %s BUSY — active=%s has_work=%s",
      m.id, tostring(st.active), tostring(st.has_work)))
  else
    print(string.format("[AutoOS] %s READY (idle)", m.id))
  end
end

if #active == 0 then
  fail("healthy pool", "no lanes available")
  return
end

print(string.format("[AutoOS] %d healthy lane(s), %d idle", #active, #idle))

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

-- Multi-recipe interleaved dispatch --------------------------------------------
if RUN_MULTI then
  print("\n[AutoOS] --- Multi-recipe dispatch (process_multi) ---")
  for i, job in ipairs(MULTI_JOBS) do
    local r = Config.constraints.recipe_baselines[job.recipe]
    print(string.format("[AutoOS]   job %d: %s %dL lanes=%s circuit=%s",
      i, job.recipe, job.volume,
      job.lanes and table.concat(job.lanes, ",") or "(auto)",
      r and tostring(r.circuit_damage) or "?"))
  end

  local multi_ok, summary = BrokerCore.process_multi(MULTI_JOBS, {
    component = component_api,
    execute_hardware = true,
    only_idle = MULTI_ONLY_IDLE,
    recover_circuits = false,
    interleave = true,
  })

  if summary.order and #summary.order > 0 then
    local order_txt = {}
    for _, step in ipairs(summary.order) do
      order_txt[#order_txt + 1] = step.lane .. ":" .. step.recipe
    end
    print("[AutoOS] dispatch order: " .. table.concat(order_txt, " → "))
  end

  if multi_ok then
    pass("process_multi", string.format("%d/%d lanes", summary.succeeded, summary.dispatched))
  else
    local detail = string.format("%d/%d succeeded", summary.succeeded, summary.dispatched)
    for id, r in pairs(summary.lanes or {}) do
      if not r.ok then
        detail = detail .. string.format("; %s: %s", id, tostring(r.err))
      end
    end
    if summary.err then detail = detail .. "; " .. summary.err end
    fail("process_multi", detail)
  end

  for _, js in ipairs(summary.jobs or {}) do
    if js.err then
      print(string.format("[AutoOS]   job %d (%s): %s", js.index, js.recipe, js.err))
    end
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
