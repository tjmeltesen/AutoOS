--[[
  AutoOS — Broker OC entry (LCR lane dispatch + array watch)

  Run in-game:
    broker_main              -- or: lua broker_main.lua
    loadfile("/home/subnet_broker/broker_main.lua")()
    loadfile("/home/subnet_broker/broker_main.lua")("test")  -- one tick, then exit
]]

local BROKER_BUILD = "2026-06-18-coroutine"

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
  local component = require("component")
  local computer = require("computer")
  local event = require("event")
  local Config = require("config")
  local Scheduler = require("coroutine_scheduler")
  local MachinePoll = require("machine_poll")
  local DescriptorCache = require("descriptor_cache")
  local CircuitManager = require("circuit_manager")
  local InterfaceStock = require("interface_stock")
  local LaneDispatch = require("lane_dispatch")
  local ArrayWatch = require("array_watch")
  local HW = require("hw")

  local ok, err = Config.validate(Config)
  if not ok then return nil, "config invalid: " .. tostring(err) end

  if not component.isAvailable("modem") then
    return nil, "no modem — needs a network card"
  end

  local modem = component.modem
  local listen_port = Config.broker_modem_port or 106
  local orch_port = Config.main_net_channel or Protocols.PORT_DEFAULT
  modem.open(listen_port)
  if orch_port ~= listen_port then modem.open(orch_port) end

  local link = {
    send = function(_, addr, msg) modem.send(addr, orch_port, msg) end,
    broadcast = function(_, msg) modem.broadcast(listen_port, msg) end,
  }

  local scheduler = Scheduler.new({ event = event, computer = computer, log = print })
  local function in_task()
    local co, is_main = coroutine.running()
    return co ~= nil and not is_main
  end
  local function yield_now()
    if in_task() then return Scheduler.yield_now() end
  end
  local function yield_sleep(seconds)
    if in_task() then return Scheduler.sleep(seconds) end
  end

  local poll = MachinePoll.new({ config = Config, component = component })
  local descriptor_cache = DescriptorCache.new({ config = Config, component = component })
  local circuit_manager = CircuitManager.new({
    config = Config,
    component = component,
    descriptor_cache = descriptor_cache,
    yield_sleep = yield_sleep,
  })
  local interface_stock = InterfaceStock.new({
    config = Config,
    component = component,
    descriptor_cache = descriptor_cache,
  })
  local lane_dispatch = LaneDispatch.new({
    config = Config,
    component = component,
    circuit_manager = circuit_manager,
    interface_stock = interface_stock,
    log = print,
    now = computer.uptime,
    yield_now = yield_now,
    yield_sleep = yield_sleep,
  })

  local watch = ArrayWatch.new({
    config = Config,
    component = component,
    poll = poll,
    circuit_manager = circuit_manager,
    descriptor_cache = descriptor_cache,
    lane_dispatch = lane_dispatch,
    link = link,
    reply_to = Config.orchestrator_address ~= "" and Config.orchestrator_address or nil,
    log = print,
    now = computer.uptime,
  })

  return {
    config = Config,
    poll = poll,
    watch = watch,
    lane_dispatch = lane_dispatch,
    scheduler = scheduler,
    state = { poll_results = {}, dirty = {}, events = {} },
    listen_port = listen_port,
    orch_port = orch_port,
  }
end

function BrokerMain.attach_tasks(ctx)
  local Scheduler = require("coroutine_scheduler")
  local Protocols = require("network_protocols")
  local scheduler = ctx.scheduler
  local state = ctx.state
  local cfg = ctx.config
  local machines = cfg.machines or {}
  local active_lane_budget = cfg.active_lane_budget
    or (cfg.scheduler and cfg.scheduler.active_lane_budget)
    or 32

  local function fast_interval()
    if ctx.watch:any_fast_tick() then return cfg.monitor_poll_s or 0.15 end
    return cfg.tick_interval or 1.0
  end

  local function wake_dispatch()
    scheduler:wake("central_dispatch")
    scheduler:wake("broker_scheduler")
    scheduler:wake_prefix("lane_")
  end

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

  scheduler:spawn("component_events", function()
    while true do
      local id = Scheduler.wait_event(function(ev)
        return ev == "component_available" or ev == "component_unavailable"
      end)
      if ctx.poll.mark_proxy_cache_stale then ctx.poll:mark_proxy_cache_stale() end
      if HW.clear_proxy_cache then HW.clear_proxy_cache() end
      state.dirty.components = true
      state.events[#state.events + 1] = { type = id }
      scheduler:wake("machine_poll")
      wake_dispatch()
      Scheduler.yield_now()
    end
  end)

  scheduler:spawn("central_input_events", function()
    while true do
      local id = Scheduler.wait_event(function(ev)
        return ev == "inventory_changed"
          or ev == "tank_changed"
          or ev == "me_interface_changed"
      end)
      state.events[#state.events + 1] = { type = id }
      scheduler:wake("central_dispatch")
      scheduler:wake("broker_scheduler")
      Scheduler.yield_now()
    end
  end)

  scheduler:spawn("machine_poll", function()
    local idx = 1
    while true do
      if #machines > 0 then
        local machine = machines[idx]
        state.poll_results[machine.id] = ctx.poll:poll_machine(machine)
        state.dirty[machine.id] = true
        scheduler:wake("lane_" .. tostring(machine.id))
        scheduler:wake("central_dispatch")
        scheduler:wake("broker_scheduler")
        idx = (idx % #machines) + 1
      end
      Scheduler.sleep(fast_interval())
    end
  end)

  scheduler:spawn("central_dispatch", function()
    while true do
      if ctx.watch.step_central then ctx.watch:step_central(state.poll_results) end
      scheduler:wake("broker_scheduler")
      Scheduler.yield_now()
      Scheduler.sleep(fast_interval())
    end
  end)

  scheduler:spawn("broker_scheduler", function()
    while true do
      if ctx.watch.step_scheduler then
        local assigned = ctx.watch:step_scheduler(state.poll_results) or {}
        for _, machine_id in ipairs(assigned) do
          scheduler:wake("lane_" .. tostring(machine_id))
        end
      end
      Scheduler.yield_now()
      Scheduler.sleep(fast_interval())
    end
  end)

  for _, machine in ipairs(machines) do
    scheduler:spawn("lane_" .. tostring(machine.id), function()
      while true do
        for _ = 1, active_lane_budget do
          ctx.watch:step_lane(machine, state.poll_results)
          Scheduler.yield_now()
          local dbg = ctx.lane_dispatch and ctx.lane_dispatch:get_lane_debug(machine.id)
          if not dbg or dbg.state == "idle" then break end
        end
        local dbg = ctx.lane_dispatch and ctx.lane_dispatch:get_lane_debug(machine.id)
        if dbg and dbg.state ~= "idle" then
          Scheduler.sleep(cfg.monitor_poll_s or 0.15)
        else
          Scheduler.sleep(cfg.tick_interval or 1.0)
        end
      end
    end)
  end

  scheduler:spawn("heartbeat", function()
    while true do
      ctx.watch:step_heartbeat()
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

  local ok_tick, err_tick = xpcall(function() ctx.watch:tick() end, debug.traceback)
  if not ok_tick then
    print("[Broker] tick error:\n" .. tostring(err_tick))
    return false
  end

  for _, m in ipairs(ctx.config.machines) do
    local dbg = ctx.lane_dispatch:get_lane_debug(m.id)
    print(string.format("[Broker] %s dispatch=%s%s",
      m.id, dbg.state,
      dbg.last_error and (" err=" .. dbg.last_error) or ""))
  end
  if ctx.config.input_mode == "central" and ctx.watch.central_dispatch then
    local cd = ctx.watch.central_dispatch:get_debug()
    print(string.format("[Broker] central state=%s bound=%s rr=%s",
      cd.state, tostring(cd.bound_machine or "none"), tostring(cd.rr_index)))
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

  local event = require("event")
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
