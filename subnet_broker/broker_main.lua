--[[
  AutoOS — Broker OC entry (LCR lane dispatch + array watch)

  Run in-game:
    broker_main              -- or: lua broker_main.lua
    loadfile("/home/subnet_broker/broker_main.lua")()
    loadfile("/home/subnet_broker/broker_main.lua")("test")  -- one tick, then exit
]]

local BROKER_BUILD = "2026-06-19-me-only"

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Protocols = require("network_protocols")
local mode = ({...})[1]

local BrokerMain = {}

local function print_lane_status(poll, machines)
  local results = poll:poll_all()
  for _, m in ipairs(machines) do
    local st = results[m.id]
    if not st or not st.available then
      print(string.format("[Broker] %s OFFLINE — %s",
        m.id, tostring(st and st.fault_message or "no gt_machine proxy")))
    elseif st.healthy then
      print(string.format("[Broker] %s OK (active=%s has_work=%s)",
        m.id, tostring(st.active), tostring(st.has_work)))
    else
      print(string.format("[Broker] %s FAULT — %s", m.id, tostring(st.fault_message)))
    end
  end
end

function BrokerMain.build()
  local ok_build, ctx_or_err = pcall(BrokerMain._build_impl)
  if ok_build then return ctx_or_err end
  return nil, tostring(ctx_or_err)
end

function BrokerMain._build_impl()
  local component = require("component")
  local computer = require("computer")
  local event = require("event")
  local Config = require("config")
  local Scheduler = require("coroutine_scheduler")
  local MachinePoll = require("machine_poll")
  local BrokerBoot = require("broker_boot")

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

  local scheduler = Scheduler.new({ event = event, computer = computer, log = print })

  -- Seed runtime deps
  pcall(registry.seed, registry, computer.uptime, print, registry.get_circuit_manager())

  local poll = MachinePoll.new({ config = Config, component = component })

  -- Phase 3 (ROB): Central dispatcher
  local ROBDispatcher = require("rob_dispatcher")
  local rob = ROBDispatcher.new(registry, Config, {
    now = computer.uptime,
    log = print,
    circuit_manager = registry.get_circuit_manager(),
  })

  return {
    config = Config,
    registry = registry,
    poll = poll,
    rob = rob,
    scheduler = scheduler,
    state = { poll_results = {}, dirty = {}, events = {} },
    listen_port = listen_port,
    orch_port = orch_port,
  }
end

function BrokerMain.attach_tasks(ctx)
  local Scheduler = require("coroutine_scheduler")
  local Protocols = require("network_protocols")
  local ok_lw, LaneWorker = pcall(require, "lane_worker")
  if not ok_lw then
    print("[Broker] lane_worker load failed: " .. tostring(LaneWorker))
    LaneWorker = nil
  end
  local scheduler = ctx.scheduler
  local state = ctx.state
  local cfg = ctx.config
  local machines = cfg.machines or {}
  local registry = ctx.registry
  local rob = ctx.rob

  local function fast_interval()
    if rob:any_fast_tick() then return cfg.monitor_poll_s or 0.15 end
    return cfg.tick_interval or 1.0
  end

  local function wake_dispatch()
    scheduler:wake("central_dispatch")
    scheduler:wake_prefix("lane_")
  end

  -- modem_rx: unchanged — relay modem messages to state.events
  scheduler:spawn("modem_rx", function()
    while true do
      local _, _, from, _, _, message = Scheduler.wait_event("modem_message")
      local pkt = Protocols.parse(message)
      if pkt and pkt.kind == Protocols.KIND.TRIGGER_CRAFT then
        print(string.format("[Broker] ignoring TRIGGER_CRAFT from %s (AE handles dispatch)",
          tostring(from)))
      end
      state.events[#state.events + 1] = { type = "modem_message", from = from, packet = pkt }
      wake_dispatch()
      Scheduler.yield_now()
    end
  end)

  -- component_events: unchanged
  scheduler:spawn("component_events", function()
    while true do
      local id = Scheduler.wait_event(function(ev)
        return ev == "component_available" or ev == "component_unavailable"
      end)
      if ctx.poll.mark_proxy_cache_stale then ctx.poll:mark_proxy_cache_stale() end
      state.dirty.components = true
      state.events[#state.events + 1] = { type = id }
      scheduler:wake("machine_poll")
      wake_dispatch()
      Scheduler.yield_now()
    end
  end)

  -- central_input_events: unchanged — inventory/tank/interface changes wake dispatch
  scheduler:spawn("central_input_events", function()
    while true do
      local id = Scheduler.wait_event(function(ev)
        return ev == "inventory_changed"
          or ev == "tank_changed"
          or ev == "me_interface_changed"
      end)
      state.events[#state.events + 1] = { type = id }
      scheduler:wake("central_dispatch")
      Scheduler.yield_now()
    end
  end)

  -- machine_poll: poll one machine per tick, share results with registry + dispatcher
  scheduler:spawn("machine_poll", function()
    local idx = 1
    while true do
      if #machines > 0 then
        local machine = machines[idx]
        local result = ctx.poll:poll_machine(machine)
        state.poll_results[machine.id] = result
        registry._poll_results[machine.id] = result
        state.dirty[machine.id] = true
        scheduler:wake("lane_" .. tostring(machine.id))
        scheduler:wake("central_dispatch")
        idx = (idx % #machines) + 1
      end
      Scheduler.sleep(fast_interval())
    end
  end)

  -- central_dispatch: ROB does buffer monitor + job creation + lane assignment in one tick
  scheduler:spawn("central_dispatch", function()
    while true do
      local result = rob:tick(state.poll_results)
      -- Wake lanes that got jobs assigned
      for _, machine_id in ipairs(result.jobs_assigned or {}) do
        scheduler:wake("lane_" .. tostring(machine_id))
      end
      -- Emit central events for health/logging
      for _, ev in ipairs(result.events or {}) do
        state.events[#state.events + 1] = ev
      end
      Scheduler.yield_now()
      Scheduler.sleep(fast_interval())
    end
  end)

  -- lane_* coroutines: pull assigned job from ROB, execute via LaneWorker, post result
  for _, machine in ipairs(machines) do
    scheduler:spawn("lane_" .. tostring(machine.id), function()
      while true do
        local job = rob:get_assigned_job(machine.id)
        if job and LaneWorker then
          local ok_exec, result = pcall(LaneWorker.execute, registry, job, machine.id)
          if not ok_exec then
            result = { status = "failed", error = "LaneWorker crashed: " .. tostring(result) }
          end
          local results_table = rob:get_results_table()
          results_table[machine.id] = result
          if result.status == "failed" then
            rob:fault_lane(machine.id, result.error or "lane worker failed")
          end
          scheduler:wake("central_dispatch")
        end
        Scheduler.yield_now()
        Scheduler.sleep(fast_interval())
      end
    end)
  end

  -- heartbeat: periodic health ping
  scheduler:spawn("heartbeat", function()
    while true do
      Scheduler.sleep(10)
    end
  end)
end

function BrokerMain.run_once()
  print("[Broker] test tick " .. BROKER_BUILD)
  local ctx, err = BrokerMain.build()
  if not ctx then
    print("[Broker] start FAILED: " .. tostring(err))
    return false
  end

  print(string.format("[Broker] subnet=%s listen=%d orch=%s",
    ctx.config.subnet_id, ctx.listen_port, ctx.config.orchestrator_address or "(none)"))
  print_lane_status(ctx.poll, ctx.config.machines)

  -- Poll all machines once so dispatcher has data
  local results = ctx.poll:poll_all()
  for mid, r in pairs(results) do
    ctx.state.poll_results[mid] = r
    ctx.registry._poll_results[mid] = r
  end

  -- Single dispatcher tick: buffer monitor + job creation + lane assignment
  local tick_result = ctx.rob:tick(ctx.state.poll_results)
  for _, ev in ipairs(tick_result.events or {}) do
    print(string.format("[Broker] event: %s %s", ev.type, tostring(ev.detail or ev.machine_id or "")))
  end

  -- Show lane state
  local dbg = ctx.rob:get_debug()
  print(string.format("[Broker] central state=%s pending=%d batch_claimed=%s",
    dbg.buffer_state, dbg.pending_jobs, tostring(dbg.batch_claimed)))
  for mid, lane in pairs(dbg.lanes) do
    print(string.format("[Broker] %s state=%s job=%s err=%s",
      mid, lane.state, tostring(lane.current_job_id or "none"),
      tostring(lane.last_error or "")))
  end
  print("[Broker] test tick done")
  return true
end

function BrokerMain.run()
  print("[Broker] starting " .. BROKER_BUILD)
  local ctx, err = BrokerMain.build()
  if not ctx then
    print("[Broker] start FAILED: " .. tostring(err))
    return false
  end

  print(string.format("[Broker] online — %s dispatch, subnet=%s, listen %d → %d, orch=%s",
    ctx.config.input_mode or "per_lane", ctx.config.subnet_id, ctx.listen_port, ctx.orch_port,
    ctx.config.orchestrator_address or "(none)"))
  print("[Broker] headless — no GPU UI; Ctrl+C to stop; use loadfile(...)(\"test\") for one tick")
  print_lane_status(ctx.poll, ctx.config.machines)

  BrokerMain.attach_tasks(ctx)
  ctx.scheduler:run()
end

local function should_autostart()
  if mode == "broker_main" then return false end
  if mode == "test" or mode == "once" then return true end
  -- ponytail: OpenOS has no arg[]; lua broker_main.lua runs under /bin/lua — skip require() only
  local info = debug.getinfo(2, "S")
  if info and info.what == "C" then return false end
  return true
end

if should_autostart() then
  if mode == "test" or mode == "once" then
    BrokerMain.run_once()
  else
    local ok, err = xpcall(BrokerMain.run, debug.traceback)
    if not ok then print("[Broker] FATAL:\n" .. tostring(err)) end
  end
end

return BrokerMain
