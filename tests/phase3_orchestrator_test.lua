#!/usr/bin/env lua
--[[
  AutoOS — Phase 3 desktop tests (orchestrator + protocol + broker slave path)

  Run: C:\Lua\lua55.exe tests\phase3_orchestrator_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/phase3_orchestrator_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "shared" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "orchestrator" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local Protocols = require("network_protocols")
local Registry = require("ae_recipe_registry")
local RegistryStore = require("registry_store")
local SubnetCache = require("subnet_cache")
local BrokerRegistry = require("broker_registry")
local CraftResolver = require("craft_resolver")
local BrokerCraftResolver = dofile(here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "craft_resolver.lua")
local Orchestrator = require("orchestrator")
local BrokerMain = require("broker_main")
local MockNetwork = require("mock_network")
local OrchConfig = require("orchestrator_config")
local BrokerConfig = require("config")

local function broker_registry_from_config(cfg)
  local r = BrokerRegistry.new(cfg)
  r:seed_from_config()
  return r
end

local ESC = string.char(27)
local function color(c, t) return ESC .. "[" .. c .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function dim(t) return color("2", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write(dim("  -  " .. tostring(detail))) end
  io.write("\n")
end

io.write("\n" .. bold("AutoOS Phase 3 — Orchestrator / Protocol Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- Protocol codec --------------------------------------------------------------
do
  local msg = Protocols.dispatch_job("job-1", 257, "polyethylene", 3000, "subnet_x", "batch")
  local pkt = Protocols.parse(msg)
  check("dispatch_job round-trip kind", pkt and pkt.kind == Protocols.KIND.DISPATCH_JOB)
  check("dispatch_job recipe_uid", pkt and pkt.recipe_uid == 257)
  check("dispatch_job volume", pkt and pkt.volume_mB == 3000)
  check("dispatch_job recipe_key", pkt and pkt.recipe_key == "polyethylene")

  local s = Protocols.parse(Protocols.broker_status("subnet_x", "job-1", "complete", "4 lanes"))
  check("broker_status phase", s and s.phase == "complete")
  check("broker_status detail", s and s.detail == "4 lanes")

  local e = Protocols.parse(Protocols.broker_event("subnet_x", "job_complete", "Polyethylene", 0, "job-1"))
  check("broker_event event", e and e.event == "job_complete")

  local ack = Protocols.parse(Protocols.craft_ack("job-1", "subnet_x"))
  check("craft_ack round-trip", ack and ack.kind == Protocols.KIND.CRAFT_ACK and ack.job_id == "job-1")

  local tc = Protocols.parse(Protocols.trigger_craft("job-2", "Polyethylene", 28000, "subnet_x"))
  check("trigger_craft volume", tc and tc.volume_mB == 28000)

  local sd = Protocols.parse(Protocols.subnet_delivery("subnet_x", "job-3", 257, "polyethylene", 3000, "uid"))
  check("subnet_delivery round-trip", sd and sd.kind == Protocols.KIND.SUBNET_DELIVERY)
  check("subnet_delivery volume", sd and sd.volume_mB == 3000)

  local da = Protocols.parse(Protocols.delivery_ack("job-3", "subnet_x"))
  check("delivery_ack round-trip", da and da.kind == Protocols.KIND.DELIVERY_ACK)

  local bad, err = Protocols.parse("GARBAGE|x")
  check("parse rejects unknown kind", bad == nil and err ~= nil)

  -- A "|" in a field must not break parsing (sanitized to "/").
  local pipe = Protocols.parse(Protocols.broker_status("s", "j", "failed", "a|b|c"))
  check("pipe in detail sanitized", pipe and pipe.detail == "a/b/c")
end

-- Registry: uid allocation + lookups ------------------------------------------
do
  local reg = Registry.new({ config = OrchConfig })
  local ok = reg:seed_from_config()
  check("registry seed ok", ok)
  check("registry validate ok", (reg:validate()))
  check("by_uid 257 -> polyethylene", reg:resolve_uid(257) and reg:resolve_uid(257).recipe_key == "polyethylene")
  check("by_uid 256 -> solder", reg:resolve_uid(256) and reg:resolve_uid(256).recipe_key == "molten_soldering_alloy")
  check("lookup_label fluid", reg:lookup_label("Ethylene") and reg:lookup_label("Ethylene").recipe_key == "polyethylene")

  -- Auto-allocate when no explicit uid; respects uid_min.
  local ok_add = reg:add("new_recipe", { fluid_label = "Acetone", fluid_requirement = 500, circuit_damage = 5 })
  check("auto-allocate uid for new recipe", ok_add)
  local row = reg:get("new_recipe")
  check("auto uid >= uid_min", row and row.recipe_uid >= OrchConfig.orchestrator.uid_min, row and row.recipe_uid)
  check("auto uid unique", row and reg:resolve_uid(row.recipe_uid).recipe_key == "new_recipe")

  -- Duplicate explicit uid rejected.
  local dup, derr = reg:add("dupe", { recipe_uid = 257, fluid_label = "X", fluid_requirement = 1 })
  check("duplicate recipe_uid rejected", dup == false and derr ~= nil)
end

-- Registry: collision mitigation (two recipes share circuit 18) ---------------
do
  local reg = Registry.new({ config = OrchConfig })
  reg:seed_from_config()
  reg:add("polyethylene_alt", { fluid_label = "Ethylene", fluid_requirement = 1000, circuit_damage = 18 })

  -- UID token path stays unambiguous.
  check("uid token resolves despite shared circuit",
    reg:resolve_uid(257).recipe_key == "polyethylene")

  -- Fallback by circuit+fluid is now ambiguous (two rows, circuit 18 / Ethylene).
  local rows = reg:resolve_delivery(18, "Ethylene")
  check("resolve_delivery finds both colliding rows", #rows == 2, #rows)
end

-- Registry: persistence (uid stable across reload) ----------------------------
do
  local reg = Registry.new({ config = OrchConfig })
  reg:seed_from_config()
  local path = here .. sep .. "_tmp_registry.lua"
  check("registry save", (reg:save(path)))

  local reg2 = Registry.new({ config = OrchConfig })
  check("registry load", (reg2:load(path)))
  check("uid preserved across reload", reg2:resolve_uid(257) and reg2:resolve_uid(257).recipe_key == "polyethylene")
  os.remove(path)

  -- Serializer is round-trippable on its own.
  local chunk = load(RegistryStore.serialize(reg.entries))
  local rows = chunk and chunk()
  check("serialize round-trip", rows and rows.polyethylene and rows.polyethylene.recipe_uid == 257)
end

-- subnet_cache: positive deltas (broker watches subnet ME) --------------------
do
  local items = { { name = "gregtech:gt.integrated_circuit", damage = 257, size = 0 } }
  local fluids = { Ethylene = 0 }
  local me = {
    getItemsInNetwork = function(filter)
      local out = {}
      for _, it in ipairs(items) do
        if not filter or not filter.name or it.name == filter.name then out[#out + 1] = it end
      end
      return out
    end,
    getFluidsInNetwork = function()
      local out = {}
      for label, amount in pairs(fluids) do out[#out + 1] = { label = label, amount = amount } end
      return out
    end,
  }
  local cache = SubnetCache.new({ config = BrokerConfig, me = me })
  local first = cache:poll()
  check("first poll seeds (no deltas)", first.seeded == true)

  items[1].size = 1
  fluids.Ethylene = 3000
  local d = cache:poll()
  check("token delta detected", d.tokens[257] == 1, d.tokens[257])
  check("fluid delta detected", d.fluids.Ethylene == 3000, d.fluids.Ethylene)

  local d2 = cache:poll()
  check("no change -> empty deltas", next(d2.tokens) == nil and next(d2.fluids) == nil)
end

-- craft_resolver (orchestrator + broker registry) -----------------------------
do
  local reg = Registry.new({ config = OrchConfig })
  reg:seed_from_config()
  local breg = broker_registry_from_config(BrokerConfig)

  local r1 = CraftResolver.resolve({ tokens = { [257] = 1 }, fluids = { Ethylene = 3000 } }, reg)
  check("resolver: uid primary match", r1.matched and r1.recipe_key == "polyethylene")
  check("resolver: volume from fluid delta", r1.volume_mB == 3000, r1.volume_mB)

  local r1b = BrokerCraftResolver.resolve({ tokens = { [257] = 1 }, fluids = {} }, breg)
  check("broker resolver: uid volume without fluid", r1b.volume_mB == 3000, r1b.volume_mB)

  -- Fallback: no token, single fluid match.
  local r2 = CraftResolver.resolve({ tokens = {}, circuits = {}, fluids = { Ethylene = 1000 } }, reg)
  check("resolver: fallback single match", r2.matched and r2.recipe_key == "polyethylene")
  check("resolver: source fallback", r2.source == "fallback")

  -- Fallback ambiguity → fault.
  reg:add("polyethylene_alt", { fluid_label = "Ethylene", fluid_requirement = 1000, circuit_damage = 18 })
  local r3 = CraftResolver.resolve({ tokens = {}, circuits = {}, fluids = { Ethylene = 1000 } }, reg)
  check("resolver: ambiguous fallback faults", r3.fault == true and not r3.matched, r3.reason)

  -- No delivery → no match, no fault.
  local r4 = CraftResolver.resolve({ tokens = {}, circuits = {}, fluids = {} }, reg)
  check("resolver: empty -> waiting", not r4.matched and not r4.fault)
end

-- Orchestrator coordinator (broker notifies orchestrator) -------------------
do
  local net = MockNetwork.new()
  local orch_addr, broker_addr, overseer_addr = "orch-1", "broker-1", "overseer-1"
  net:node(broker_addr); net:node(overseer_addr)
  local orch_link = net:node(orch_addr)

  local reg = Registry.new({ config = OrchConfig })
  reg:seed_from_config()
  local cfg = {}
  for k, v in pairs(OrchConfig) do cfg[k] = v end
  cfg.broker_address = broker_addr

  local logs = {}
  local orch = Orchestrator.new({
    config = cfg, registry = reg,
    link = orch_link, now = function() return 0 end,
    log = function(m) logs[#logs + 1] = m end,
  })

  orch:on_message(broker_addr, Protocols.subnet_delivery(
    cfg.subnet_id, "universal_chemical_mv_01-1", 257, "polyethylene", 3000, "uid"
  ))
  net:deliver()
  check("orchestrator tracks delivery", orch.jobs["universal_chemical_mv_01-1"] ~= nil)
  check("orchestrator state tracking", orch.state == "tracking")

  local acks = net:drain(broker_addr)
  local saw_ack = false
  for _, m in ipairs(acks) do
    local p = Protocols.parse(m.msg)
    if p and p.kind == Protocols.KIND.DELIVERY_ACK then saw_ack = true end
  end
  check("delivery_ack sent to broker", saw_ack)

  orch:on_message(broker_addr, Protocols.broker_status(cfg.subnet_id, "universal_chemical_mv_01-1", "running", "2/2"))
  orch:on_message(broker_addr, Protocols.craft_done("universal_chemical_mv_01-1", cfg.subnet_id))
  net:deliver()
  check("orchestrator idle after craft_done", orch.state == "idle")
  local ov = net:drain(overseer_addr)
  local saw_complete = false
  for _, m in ipairs(ov) do
    local p = Protocols.parse(m.msg)
    if p and p.event == Protocols.EVENT.JOB_COMPLETE then saw_complete = true end
  end
  check("job_complete broadcast seen", saw_complete)
end

-- Broker watch tick → notify orchestrator -------------------------------------
do
  local net = MockNetwork.new()
  local orch_addr, broker_addr = "orch-1", "broker-1"
  net:node(orch_addr)
  local broker_link = net:node(broker_addr)

  local seq = {
    { seeded = true },
    { tokens = {}, circuits = {}, fluids = { Ethylene = 3000 } },
  }
  local idx = 0
  local fake_cache = { poll = function() idx = idx + 1; return seq[idx] or { tokens = {}, fluids = {} } end }

  local core_calls = {}
  local deps = {
    config = BrokerConfig,
    broker_core = {
      process_batch = function(recipe_key, volume)
        core_calls[#core_calls + 1] = { recipe = recipe_key, volume = volume }
        return true, { dispatched = 1, succeeded = 1, failed = 0, lanes = { machine_01 = {} } }
      end,
    },
    circuit_manager = nil,
    link = broker_link, reply_to = orch_addr,
    subnet_cache = fake_cache,
    registry = broker_registry_from_config(BrokerConfig),
    craft_resolver = BrokerCraftResolver,
    poll = nil, log = function() end, busy = false,
  }

  BrokerMain.tick(deps)
  check("broker seed tick no dispatch", #core_calls == 0)
  BrokerMain.tick(deps)
  check("broker tick dispatches on fluid delta", #core_calls == 1)
  check("broker process_batch polyethylene", core_calls[1] and core_calls[1].recipe == "polyethylene")

  net:deliver()
  local orch_in = net:drain(orch_addr)
  local saw_delivery = false
  for _, m in ipairs(orch_in) do
    local p = Protocols.parse(m.msg)
    if p and p.kind == Protocols.KIND.SUBNET_DELIVERY then saw_delivery = true end
  end
  check("broker sent SUBNET_DELIVERY to orchestrator", saw_delivery)
end

-- Broker slave: handle_job path -----------------------------------------------
do
  local net = MockNetwork.new()
  local orch_addr, broker_addr = "orch-1", "broker-1"
  net:node(orch_addr)
  local broker_link = net:node(broker_addr)

  local core_calls = {}
  local fake_core = {
    process_batch = function(recipe_key, volume, _pool, opts)
      core_calls[#core_calls + 1] = { recipe = recipe_key, volume = volume, opts = opts }
      return true, {
        dispatched = 2, succeeded = 2, failed = 0,
        lanes = { machine_01 = { ok = true }, machine_02 = { ok = true } },
      }
    end,
  }
  local recovered = {}
  local fake_cm = {
    recover_all = function(_, ids)
      local s = {}
      for _, id in ipairs(ids) do recovered[id] = true; s[id] = { ok = true } end
      return s
    end,
  }

  local deps = {
    config = BrokerConfig, broker_core = fake_core, circuit_manager = fake_cm,
    link = broker_link, reply_to = orch_addr, poll = nil, log = function() end,
  }

  local pkt = Protocols.parse(Protocols.dispatch_job("job-9", 257, "polyethylene", 3000, BrokerConfig.subnet_id, "batch"))
  local res = BrokerMain.handle_job(pkt, deps)
  check("broker handle_job ok", res.ok and res.phase == "complete")
  check("process_batch called with recipe", core_calls[1] and core_calls[1].recipe == "polyethylene")
  check("process_batch recover_circuits=false", core_calls[1] and core_calls[1].opts.recover_circuits == false)
  check("circuits recovered for dispatched lanes", recovered.machine_01 and recovered.machine_02)

  net:deliver()
  local orch_in = net:drain(orch_addr)
  local kinds = {}
  for _, m in ipairs(orch_in) do
    local p = Protocols.parse(m.msg)
    if p then kinds[p.kind] = (p.kind == Protocols.KIND.BROKER_STATUS) and (kinds[p.kind] or "") .. p.phase .. "," or true end
  end
  check("broker sent craft_done", kinds[Protocols.KIND.CRAFT_DONE] == true)
  check("broker status reached complete", (kinds[Protocols.KIND.BROKER_STATUS] or ""):find("complete"))
  check("legacy DISPATCH_JOB: no craft_ack in handle_job", kinds[Protocols.KIND.CRAFT_ACK] == nil)

  -- uid mismatch → failed, process_batch NOT called again.
  local before = #core_calls
  local pkt_bad = Protocols.parse(Protocols.dispatch_job("job-10", 999, "polyethylene", 3000, BrokerConfig.subnet_id, "batch"))
  local res_bad = BrokerMain.handle_job(pkt_bad, deps)
  check("uid mismatch fails job", not res_bad.ok and res_bad.phase == "failed")
  check("process_batch not run on mismatch", #core_calls == before)

  -- unknown recipe → failed.
  local pkt_unk = Protocols.parse(Protocols.dispatch_job("job-11", 1, "no_such_recipe", 3000, BrokerConfig.subnet_id, "batch"))
  local res_unk = BrokerMain.handle_job(pkt_unk, deps)
  check("unknown recipe fails job", not res_unk.ok and res_unk.phase == "failed")
end

-- Summary ---------------------------------------------------------------------
io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Phase 3 result:"), green(tostring(passed)),
  failed == 0 and dim("0") or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
