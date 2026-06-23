--[[
  AutoOS — Broker bootstrap
  Houses _build_impl (subsystem wiring) and attach_tasks (task graph
  construction).  This is the only module that touches multiple subsystems
  directly — it is the "glue" that wires everything together.
]]
local Bootstrap = {}

function Bootstrap._build_impl(log)
  log = log or print
  local component = require("component")
  local computer = require("computer")
  local event = require("event")
  local Config = require("config")
  local Scheduler = require("coroutine_scheduler")
  local MachinePoll = require("machine_poll")
  local BrokerBoot = require("broker_boot")
  local RegistryAdapter = require("broker_registry_adapter")
  local Protocols = require("network_protocols")
  local FaultNet = require("fault_net")

  -- Phase 1 (MMU): Static hardware registry
  local ok_boot, registry_or_err = pcall(BrokerBoot.boot)
  if not ok_boot then error("boot() crashed: " .. tostring(registry_or_err), 0) end
  local registry = registry_or_err
  if not registry then error("boot returned nil: " .. tostring(registry), 0) end

  -- Config sanity checks (catch common miswires early)
  do
    local machines = Config.machines or {}
    for _, m in ipairs(machines) do
      if type(m.id) ~= "string" or m.id == "" then
        error("config: machine has invalid id: " .. tostring(m.id), 0)
      end
      if not m.interface_address or m.interface_address == "" then
        log(string.format("[BS] WARN: %s has no interface_address (shared_interface=%s)",
          m.id, tostring(Config.shared_interface_address or "(none)")))
      end
      if not m.item_transposer_address or m.item_transposer_address == "" then
        error("config: " .. m.id .. " has no item_transposer_address", 0)
      end
    end
    local ids = {}
    for _, m in ipairs(machines) do
      if ids[m.id] then error("config: duplicate machine id: " .. m.id, 0) end
      ids[m.id] = true
    end
    if Config.subnet_id == nil or Config.subnet_id == "" then
      log("[BS] WARN: subnet_id is empty — BROKER_HEALTH will be anonymous")
    end
    log(string.format("[BS] config OK: subnet=%s machines=%d orch=%s ports=%d->%d",
      tostring(Config.subnet_id), #machines,
      tostring(Config.orchestrator_address or "(none)"),
      Config.broker_modem_port or 106, Config.main_net_channel or 105))
  end

  if not component.isAvailable("modem") then
    error("no modem — needs a network card", 0)
  end

  local modem = component.modem
  local listen_port = Config.broker_modem_port or 106
  local orch_port = Config.main_net_channel or Protocols.PORT_DEFAULT
  modem.open(listen_port)
  if orch_port ~= listen_port then modem.open(orch_port) end

  -- Fault ring buffer (shared across all fault_net captures)
  local faults = { items = {}, head = 1, count = 0, max = 100 }

  local scheduler = Scheduler.new({
    event = event,
    computer = computer,
    log = log,
    fault_capture = function(tag, err, extra)
      FaultNet.capture({ log = log, faults = faults }, tag, err, extra)
    end,
  })

  -- Seed runtime deps (registry adapter centralizes all registry mutations)
  RegistryAdapter.seed_runtime(registry, computer.uptime, log)

  local poll = MachinePoll.new({ config = Config, component = component })

  -- Phase 3 (ROB): Central dispatcher
  local ROBDispatcher = require("rob_dispatcher")
  local rob = ROBDispatcher.new(registry, Config, {
    now = computer.uptime,
    log = log,
    circuit_manager = registry.get_circuit_manager(),
  })

  -- Inject transport lock release into registry (consumed by LaneWorker)
  RegistryAdapter.inject_transport_locks(registry, rob)

  -- Wire fault_net into the dispatcher so services can capture silent failures
  rob._fault = function(tag, err, extra)
    FaultNet.capture({ log = log, faults = faults }, tag, err, extra)
  end

  -- Give the dispatcher a direct lane-wake callback so it doesn't depend
  -- on task_central_dispatch to relay wakes.
  rob._wake_lane = function(machine_id)
    local name = "lane_" .. tostring(machine_id)
    -- Gate diagnostics: log what we know before waking
    local lane = rob._lanes and rob._lanes[machine_id]
    local lane_state = lane and lane.state or "nil"
    local job_id = lane and lane.current_job_id or "nil"
    local pending_n = rob._pending_jobs and #rob._pending_jobs or 0

    local ok = scheduler:wake(name)
    if ok then
      log(string.format("[WAKE] %s -> true (lane=%s job=%s pending=%d)",
        name, lane_state, tostring(job_id), pending_n))
    else
      log(string.format("[WAKE] %s -> FALSE — task not found in scheduler (lane=%s job=%s pending=%d)",
        name, lane_state, tostring(job_id), pending_n))
    end
  end

  return {
    config = Config,
    registry = registry,
    poll = poll,
    rob = rob,
    scheduler = scheduler,
    modem = modem,
    computer = computer,
    state = { poll_results = {}, dirty = {}, events = {} },
    listen_port = listen_port,
    orch_port = orch_port,
    log = log,
    faults = faults,
    fault_net = FaultNet,
  }
end

function Bootstrap.attach_tasks(ctx)
  local log = ctx.log or print
  log("[BS] attach_tasks START")

  -- Load optional LaneWorker and store on context so lane tasks can reach it
  local ok_lw, LaneWorker = pcall(require, "lane_worker")
  if not ok_lw then
    log("[BS] lane_worker load FAILED: " .. tostring(LaneWorker))
    LaneWorker = nil
  else
    log("[BS] lane_worker loaded: " .. tostring(LaneWorker ~= nil))
  end
  ctx._lane_worker_module = LaneWorker

  -- Thread handles for modem comms (killed by _stop_broker in broker_ui)
  ctx._modem_threads = {}

  -- modem_rx / heartbeat need real modem handle + orch port
  if ctx.modem and ctx.orch_port then
    log("[BS] spawning modem_rx + heartbeat")
    require("tasks.task_modem_rx").spawn(ctx)
    require("tasks.task_heartbeat").spawn(ctx)
  else
    log("[BS] SKIP modem tasks (no modem or orch_port)")
  end

  -- component_events needs poll proxy cache
  if ctx.poll and ctx.poll.mark_proxy_cache_stale then
    log("[BS] spawning component_events")
    require("tasks.task_component_events").spawn(ctx)
  else
    log("[BS] SKIP component_events (no poll.mark_proxy_cache_stale)")
  end

  -- central_input_events: no special deps
  log("[BS] spawning central_input_events")
  require("tasks.task_central_input_events").spawn(ctx)

  -- machine_poll needs poll:poll_machine
  if ctx.poll and ctx.poll.poll_machine then
    log("[BS] spawning machine_poll")
    require("tasks.task_machine_poll").spawn(ctx)
  else
    log("[BS] SKIP machine_poll (no poll.poll_machine)")
  end

  -- central_dispatch + lane_* need rob dispatcher
  if ctx.rob and ctx.rob.tick then
    log(string.format("[BS] spawning central_dispatch + %d lane tasks (rob=%s)",
      #(ctx.config.machines or {}), tostring(ctx.rob):sub(8)))
    require("tasks.task_central_dispatch").spawn(ctx)
    require("tasks.task_lane_worker").spawn_all(ctx)
  else
    log("[BS] SKIP central_dispatch+lane (no rob.tick)")
  end

  log("[BS] attach_tasks DONE")
end

return Bootstrap
