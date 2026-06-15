--[[
  AutoOS — Broker OC (Phase 3)

  Watches the SUBNET ME for delivery deltas, resolves the recipe locally,
  notifies the orchestrator (SUBNET_DELIVERY + BROKER_STATUS), and runs
  Phase 2 lane dispatch. Also accepts legacy DISPATCH_JOB from link_test.

  Run in-game:
    lua broker_main.lua
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Protocols = require("network_protocols")

local BrokerMain = {}

local GRACE_IDLE_ATTEMPTS = 30
local GRACE_IDLE_SLEEP = 1.0

local function recipe_baseline(config, recipe_key)
  return config.constraints
    and config.constraints.recipe_baselines
    and config.constraints.recipe_baselines[recipe_key]
end

local function validate_job(config, pkt, registry)
  if type(pkt.recipe_key) ~= "string" or pkt.recipe_key == "" then
    return false, "missing recipe_key"
  end
  local rule = (registry and registry.entries and registry.entries[pkt.recipe_key])
    or recipe_baseline(config, pkt.recipe_key)
  if not rule then return false, "unknown recipe_key " .. pkt.recipe_key end
  if rule.recipe_uid ~= nil and pkt.recipe_uid ~= nil and rule.recipe_uid ~= pkt.recipe_uid then
    return false, string.format(
      "recipe_uid mismatch: job %s, baseline %s", tostring(pkt.recipe_uid), tostring(rule.recipe_uid)
    )
  end
  return true
end

local function dispatched_lanes(summary)
  local ids = {}
  for id, lane in pairs(summary.lanes or {}) do
    if lane then ids[#ids + 1] = id end
  end
  return ids
end

local function wait_until_idle(poll, lane_ids, sleep, attempts)
  if not poll or #lane_ids == 0 then return end
  for _ = 1, attempts do
    local results = poll:poll_all()
    local all_idle = true
    for _, id in ipairs(lane_ids) do
      local st = results[id]
      if st and st.available and (st.active or st.has_work) then
        all_idle = false
        break
      end
    end
    if all_idle then return end
    if sleep then sleep(GRACE_IDLE_SLEEP) end
  end
end

function BrokerMain.handle_job(pkt, deps)
  local config = deps.config
  local link = deps.link
  local reply_to = deps.reply_to or config.orchestrator_address
  local subnet_id = config.subnet_id
  local log = deps.log or function() end

  local function status(phase, detail)
    if link and reply_to and reply_to ~= "" then
      link:send(reply_to, Protocols.broker_status(subnet_id, pkt.job_id, phase, detail))
    end
  end
  local function fail(detail)
    log("[Broker] job " .. tostring(pkt.job_id) .. " FAILED: " .. tostring(detail))
    status(Protocols.PHASE.FAILED, detail)
    if link and reply_to and reply_to ~= "" then
      link:send(reply_to, Protocols.craft_fail(pkt.job_id, subnet_id, detail))
    end
    return { ok = false, phase = Protocols.PHASE.FAILED, err = detail }
  end

  local ok_valid, verr = validate_job(config, pkt, deps.registry)
  if not ok_valid then return fail(verr) end

  status(Protocols.PHASE.DISPATCHING, pkt.recipe_key)
  log(string.format("[Broker] job %s: %s %dmB (uid=%s)",
    tostring(pkt.job_id), pkt.recipe_key, pkt.volume_mB or 0, tostring(pkt.recipe_uid)))

  local all_ok, summary = deps.broker_core.process_batch(
    pkt.recipe_key, pkt.volume_mB, nil, { recover_circuits = false }
  )
  summary = summary or { lanes = {}, dispatched = 0, succeeded = 0, failed = 0 }

  if summary.dispatched == 0 then
    return fail("no lanes dispatched (volume too low or no healthy lanes)")
  end

  status(Protocols.PHASE.RUNNING,
    string.format("%d/%d lanes", summary.succeeded or 0, summary.dispatched or 0))

  local lane_ids = dispatched_lanes(summary)
  wait_until_idle(deps.poll, lane_ids, deps.sleep, deps.grace_attempts or GRACE_IDLE_ATTEMPTS)

  if deps.circuit_manager and #lane_ids > 0 then
    status(Protocols.PHASE.RECOVERING, tostring(#lane_ids) .. " lanes")
    local rec = deps.circuit_manager:recover_all(lane_ids)
    for id, r in pairs(rec) do
      if not r.ok then log("[Broker] recover " .. id .. " failed: " .. tostring(r.err)) end
    end
  end

  if not all_ok or (summary.failed or 0) > 0 then
    return fail(string.format("%d lane(s) failed during dispatch", summary.failed or 0))
  end

  status(Protocols.PHASE.COMPLETE, string.format("%d lanes", summary.succeeded or 0))
  if link and reply_to and reply_to ~= "" then
    link:send(reply_to, Protocols.craft_done(pkt.job_id, subnet_id))
  end
  log("[Broker] job " .. tostring(pkt.job_id) .. " complete")
  return { ok = true, phase = Protocols.PHASE.COMPLETE, summary = summary }
end

--- Notify orchestrator and run a resolved subnet delivery.
function BrokerMain.run_delivery(res, deps)
  if deps.busy then return false end
  deps.busy = true
  deps._seq = (deps._seq or 0) + 1
  local job_id = string.format("%s-%d", deps.config.subnet_id, deps._seq)
  local reply_to = deps.reply_to or deps.config.orchestrator_address
  local row = res.row

  if deps.link and reply_to and reply_to ~= "" then
    deps.link:send(reply_to, Protocols.subnet_delivery(
      deps.config.subnet_id, job_id, res.recipe_uid, res.recipe_key, res.volume_mB, res.source or ""
    ))
    deps.link:send(reply_to, Protocols.broker_event(
      deps.config.subnet_id, Protocols.EVENT.DISPATCH_START,
      row.display_name or row.recipe_key, res.volume_mB, job_id
    ))
  end

  local pkt = {
    job_id = job_id, recipe_uid = res.recipe_uid, recipe_key = res.recipe_key,
    volume_mB = res.volume_mB, subnet_id = deps.config.subnet_id,
  }
  local result = BrokerMain.handle_job(pkt, deps)
  deps.busy = false
  return result.ok
end

--- Poll subnet ME; resolve and dispatch when a delivery delta appears.
function BrokerMain.maybe_scan(deps)
  local cfg = deps.config
  if cfg.pattern_scan_enabled == false or not deps.me then return end
  local interval = cfg.pattern_scan_interval_s or 600
  local computer = require("computer")
  local now = computer.uptime()
  if now - (deps._last_scan or 0) < interval then return end
  deps._last_scan = now

  local RecipeScanner = require("recipe_scanner")
  local added, updated = RecipeScanner.scan(deps.me, deps.registry, {
    config = cfg, log = deps.log, now = now,
  })
  if added > 0 or updated > 0 then
    deps.log(string.format("[Broker] pattern scan: %d new, %d updated", added, updated))
    if cfg.registry_persist then deps.registry:save() end
  end
end

function BrokerMain.tick(deps)
  BrokerMain.maybe_scan(deps)
  if deps.busy or not deps.subnet_cache then return end

  local deltas = deps.subnet_cache:poll()
  if deltas.seeded then
    if not deps._seed_logged then
      deps._seed_logged = true
      (deps.log or print)("[Broker] subnet baseline seeded — watching for deliveries")
    end
    return
  end

  local res = deps.craft_resolver.resolve(deltas, deps.registry)
  if res.fault then
    (deps.log or print)("[Broker] FAULT " .. tostring(res.reason))
    return
  end
  if not res.matched or res.volume_mB <= 0 then return end

  local min = deps.config.min_dispatch_mB
  if min and res.volume_mB < min then return end

  (deps.log or print)(string.format(
    "[Broker] subnet delivery: %s %dmB (uid=%d, source=%s)",
    res.recipe_key, res.volume_mB, res.recipe_uid or 0, tostring(res.source)
  ))
  BrokerMain.run_delivery(res, deps)
end

function BrokerMain.on_message(from, message, deps)
  local pkt = Protocols.parse(message)
  if not pkt or pkt.kind ~= Protocols.KIND.DISPATCH_JOB then return false end
  deps.reply_to = (deps.config.orchestrator_address ~= "" and deps.config.orchestrator_address) or from
  if deps.link and deps.reply_to and deps.reply_to ~= "" then
    deps.link:send(deps.reply_to, Protocols.craft_ack(pkt.job_id, deps.config.subnet_id))
  end
  deps.busy = true
  BrokerMain.handle_job(pkt, deps)
  deps.busy = false
  return true
end

function BrokerMain.run()
  local component = require("component")
  local event = require("event")
  local HW = require("hw")
  local Config = require("config")
  local BrokerCore = require("broker_core")
  local MachinePoll = require("machine_poll")
  local CircuitManager = require("circuit_manager")
  local SubnetCache = require("subnet_cache")
  local BrokerRegistry = require("broker_registry")
  local CraftResolver = require("craft_resolver")
  local RecipeScanner = require("recipe_scanner")

  if not component.isAvailable("modem") then
    print("[Broker] no modem — needs a network card")
    return
  end
  if not Config.subnet_me_address or Config.subnet_me_address == "" then
    print("[Broker] subnet_me_address empty — set subnet ME UUID in config.lua")
    return
  end

  local modem = component.modem
  local listen_port = Config.broker_modem_port or Protocols.PORT_DEFAULT
  local orch_port = Config.main_net_channel or Protocols.PORT_DEFAULT
  modem.open(listen_port)
  if orch_port ~= listen_port then modem.open(orch_port) end

  local link = {
    send = function(_, addr, msg) modem.send(addr, orch_port, msg) end,
    broadcast = function(_, msg) modem.broadcast(listen_port, msg) end,
  }
  local me = component.proxy(Config.subnet_me_address)
  local registry = BrokerRegistry.new(Config)
  if Config.registry_persist then registry:load() end
  registry:seed_from_config()

  if Config.pattern_scan_enabled ~= false then
    local added = RecipeScanner.scan(me, registry, {
      config = Config, log = print, now = require("computer").uptime(),
    })
    if added > 0 then
      print("[Broker] boot scan: " .. added .. " new pattern(s)")
      if Config.registry_persist then registry:save() end
    end
  end

  local deps = {
    config = Config, broker_core = BrokerCore, link = link, me = me,
    poll = MachinePoll.new({ config = Config, component = component }),
    circuit_manager = CircuitManager.new({ config = Config, component = component }),
    subnet_cache = SubnetCache.new({ config = Config, component = component, me = me }),
    registry = registry,
    craft_resolver = CraftResolver,
    sleep = HW.sleep, log = print,
    reply_to = Config.orchestrator_address ~= "" and Config.orchestrator_address or nil,
    busy = false, _seq = 0, _last_scan = require("computer").uptime(),
  }

  local interval = Config.tick_interval or 1.0
  print(string.format("[Broker] online — watch subnet ME, notify orch %s, listen %d → %d",
    deps.reply_to or "(learn)", listen_port, orch_port))

  while true do
    local id, _, from, _, _, message = event.pull(interval, "modem_message")
    if id == "modem_message" then
      pcall(BrokerMain.on_message, from, message, deps)
    else
      pcall(BrokerMain.tick, deps)
    end
  end
end

local function is_direct_run()
  if not arg or not arg[0] then return false end
  local script = arg[0]:gsub("\\", "/")
  local name = script:match("([^/]+)$") or script
  return name == "broker_main.lua" or name:find("broker_main", 1, true) ~= nil
end

if is_direct_run() then
  print("[Broker] starting...")
  local ok, err = xpcall(BrokerMain.run, debug.traceback)
  if not ok then print("[Broker] FATAL:\n" .. tostring(err)) end
end

return BrokerMain
