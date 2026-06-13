--[[
  AutoOS — Broker OC modem slave (Phase 3)

  Slim loop: receive DISPATCH_JOB from the Orchestrator OC, run the existing
  Phase 2 lane dispatch (broker_core.process_batch), wait for dispatched lanes
  to finish, recover circuits, and reply with BROKER_STATUS. The broker never
  touches the subnet ME registry / getCraftables — it only drives lanes.

  Tested via handle_job(packet, deps) with injected broker_core / poll /
  circuit_manager / link; run() wires the real OC event loop.

  References: plan phase_3_orchestrator "Broker OC — slim broker_main"
]]

local Protocols = require("network_protocols")

local BrokerMain = {}

local GRACE_IDLE_ATTEMPTS = 30
local GRACE_IDLE_SLEEP = 1.0

local function recipe_baseline(config, recipe_key)
  return config.constraints
    and config.constraints.recipe_baselines
    and config.constraints.recipe_baselines[recipe_key]
end

--- Validate the job against local baselines. Returns ok, err.
local function validate_job(config, pkt)
  if type(pkt.recipe_key) ~= "string" or pkt.recipe_key == "" then
    return false, "missing recipe_key"
  end
  local rule = recipe_baseline(config, pkt.recipe_key)
  if not rule then
    return false, "unknown recipe_key " .. pkt.recipe_key
  end
  if rule.recipe_uid ~= nil and pkt.recipe_uid ~= nil and rule.recipe_uid ~= pkt.recipe_uid then
    return false, string.format(
      "recipe_uid mismatch: job %s, baseline %s", tostring(pkt.recipe_uid), tostring(rule.recipe_uid)
    )
  end
  return true
end

--- Lanes that received work in a process_batch summary.
local function dispatched_lanes(summary)
  local ids = {}
  for id, lane in pairs(summary.lanes or {}) do
    if lane then ids[#ids + 1] = id end
  end
  return ids
end

--- Poll dispatched lanes until all idle or attempts exhausted.
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

--- Handle one DISPATCH_JOB packet. Sends BROKER_STATUS via deps.link.
---@param pkt table parsed DISPATCH_JOB
---@param deps table { config, broker_core, link, reply_to, poll?, circuit_manager?, sleep?, log? }
---@return table result { ok, phase, summary?, err? }
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

  local ok_valid, verr = validate_job(config, pkt)
  if not ok_valid then return fail(verr) end

  -- Acknowledge receipt, then begin.
  if link and reply_to and reply_to ~= "" then
    link:send(reply_to, Protocols.craft_ack(pkt.job_id, subnet_id))
  end
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

  -- Recover circuits from every dispatched lane.
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

--- Route any modem message. Returns true if it was a DISPATCH_JOB we handled.
function BrokerMain.on_message(from, message, deps)
  local pkt = Protocols.parse(message)
  if not pkt or pkt.kind ~= Protocols.KIND.DISPATCH_JOB then
    return false
  end
  deps.reply_to = (deps.config.orchestrator_address ~= "" and deps.config.orchestrator_address) or from
  BrokerMain.handle_job(pkt, deps)
  return true
end

-- In-game loop ----------------------------------------------------------------

function BrokerMain.run()
  local sep = package.config:sub(1, 1)
  local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
  package.path = here .. sep .. "?.lua;" .. package.path

  local component = require("component")
  local event = require("event")
  local computer = require("computer")
  local HW = require("hw")
  local Config = require("config")
  local BrokerCore = require("broker_core")
  local MachinePoll = require("machine_poll")
  local CircuitManager = require("circuit_manager")

  if not component.isAvailable("modem") then
    print("[Broker] no modem — Phase 3 slave needs a network card")
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
  local poll = MachinePoll.new({ config = Config, component = component })
  local circuit_manager = CircuitManager.new({ config = Config, component = component })

  local deps = {
    config = Config, broker_core = BrokerCore, link = link,
    poll = poll, circuit_manager = circuit_manager,
    sleep = HW.sleep, log = print,
  }

  print(string.format("[Broker] modem slave online — subnet '%s', listen %d → orch %d",
    Config.subnet_id, listen_port, orch_port))
  while true do
    local _, _, from, _, _, message = event.pull("modem_message")
    pcall(BrokerMain.on_message, from, message, deps)
  end
end

if arg and arg[0] and arg[0]:find("broker_main") then
  BrokerMain.run()
end

return BrokerMain
