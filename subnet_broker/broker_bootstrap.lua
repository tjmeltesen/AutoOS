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

  -- Phase 1 (MMU): Static hardware registry
  local ok_boot, registry_or_err = pcall(BrokerBoot.boot)
  if not ok_boot then error("boot() crashed: " .. tostring(registry_or_err), 0) end
  local registry = registry_or_err
  if not registry then error("boot returned nil: " .. tostring(registry), 0) end

  if not component.isAvailable("modem") then
    error("no modem — needs a network card", 0)
  end

  local modem = component.modem
  local listen_port = Config.broker_modem_port or 106
  local orch_port = Config.main_net_channel or Protocols.PORT_DEFAULT
  modem.open(listen_port)
  if orch_port ~= listen_port then modem.open(orch_port) end

  local scheduler = Scheduler.new({ event = event, computer = computer, log = log })

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

  -- Give the dispatcher a direct lane-wake callback so it doesn't depend
  -- on task_central_dispatch to relay wakes.
  rob._wake_lane = function(machine_id)
    scheduler:wake("lane_" .. tostring(machine_id))
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
  }
end

function Bootstrap.attach_tasks(ctx)
  local log = ctx.log or print

  -- Load optional LaneWorker and store on context so lane tasks can reach it
  local ok_lw, LaneWorker = pcall(require, "lane_worker")
  if not ok_lw then
    log("[Broker] lane_worker load failed: " .. tostring(LaneWorker))
    LaneWorker = nil
  end
  ctx._lane_worker_module = LaneWorker

  -- Thread handles for modem comms (killed by _stop_broker in broker_ui)
  ctx._modem_threads = {}

  -- Spawn all tasks via their respective modules.
  -- Guard each spawn so partial contexts (tests, headless UI) don't crash
  -- on missing hardware proxies — every task module is independently optional.

  -- modem_rx / heartbeat need real modem handle + orch port
  if ctx.modem and ctx.orch_port then
    require("tasks.task_modem_rx").spawn(ctx)
    require("tasks.task_heartbeat").spawn(ctx)
  end

  -- component_events needs poll proxy cache
  if ctx.poll and ctx.poll.mark_proxy_cache_stale then
    require("tasks.task_component_events").spawn(ctx)
  end

  -- central_input_events: no special deps beyond scheduler + state (always on ctx)
  require("tasks.task_central_input_events").spawn(ctx)

  -- machine_poll needs poll:poll_machine
  if ctx.poll and ctx.poll.poll_machine then
    require("tasks.task_machine_poll").spawn(ctx)
  end

  -- central_dispatch + lane_* need rob dispatcher
  if ctx.rob and ctx.rob.tick then
    require("tasks.task_central_dispatch").spawn(ctx)
    require("tasks.task_lane_worker").spawn_all(ctx)
  end
end

return Bootstrap
