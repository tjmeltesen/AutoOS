--[[
  AutoOS — Broker OC entry (LCR lane dispatch + array watch)

  Run in-game: lua broker_main.lua
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Protocols = require("network_protocols")

local BrokerMain = {}

function BrokerMain.run()
  local component = require("component")
  local event = require("event")
  local computer = require("computer")
  local Config = require("config")
  local MachinePoll = require("machine_poll")
  local CircuitManager = require("circuit_manager")
  local LaneDispatch = require("lane_dispatch")
  local ArrayWatch = require("array_watch")

  local ok, err = Config.validate(Config)
  if not ok then
    print("[Broker] config invalid: " .. tostring(err))
    return
  end

  if not component.isAvailable("modem") then
    print("[Broker] no modem — needs a network card")
    return
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

  local poll = MachinePoll.new({ config = Config, component = component })
  local circuit_manager = CircuitManager.new({ config = Config, component = component })
  local lane_dispatch = LaneDispatch.new({
    config = Config,
    component = component,
    circuit_manager = circuit_manager,
    log = print,
    now = computer.uptime,
  })

  local watch = ArrayWatch.new({
    config = Config,
    component = component,
    poll = poll,
    circuit_manager = circuit_manager,
    lane_dispatch = lane_dispatch,
    link = link,
    reply_to = Config.orchestrator_address ~= "" and Config.orchestrator_address or nil,
    log = print,
    now = computer.uptime,
  })

  print(string.format("[Broker] online — LCR dispatch, subnet=%s, listen %d → %d, orch=%s",
    Config.subnet_id, listen_port, orch_port, Config.orchestrator_address or "(none)"))
  print("[Broker] headless — no GPU UI; status lines below + modem telemetry to orchestrator")
  print_lane_status(poll, Config.machines)

  while true do
    local interval = watch:any_fast_tick()
      and (Config.monitor_poll_s or 0.15)
      or (Config.tick_interval or 1.0)
    local id, _, from, _, _, message = event.pull(interval, "modem_message")
    if id == "modem_message" then
      local pkt = Protocols.parse(message)
      if pkt and pkt.kind == Protocols.KIND.TRIGGER_CRAFT then
        print(string.format("[Broker] ignoring TRIGGER_CRAFT from %s (AE handles dispatch)", tostring(from)))
      end
    else
      local ok_tick, err_tick = xpcall(function() watch:tick() end, debug.traceback)
      if not ok_tick then
        print("[Broker] tick error:\n" .. tostring(err_tick))
      end
    end
  end
end

local function is_direct_run()
  -- ponytail: OpenOS has no global arg[] — use process.info() when arg is missing
  if arg and arg[0] then
    local script = arg[0]:gsub("\\", "/")
    local name = script:match("([^/]+)$") or script
    if name == "broker_main.lua" or name:find("broker_main", 1, true) then return true end
  end
  local ok, proc = pcall(require, "process")
  if ok and proc and proc.info then
    local path = proc.info()
    if type(path) == "string" and path:find("broker_main", 1, true) then return true end
  end
  return false
end

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

if is_direct_run() then
  print("[Broker] starting...")
  local ok, err = xpcall(BrokerMain.run, debug.traceback)
  if not ok then print("[Broker] FATAL:\n" .. tostring(err)) end
end

return BrokerMain
