--[[
  AutoOS — Broker OC entry (Array Watch mode)

  AE2 handles bulk item/fluid dispatch. Broker now:
    * polls machine health
    * shuts machines down on maintenance faults
    * recovers non-consumable circuits when a lane goes idle
    * reports lane status to orchestrator

  Run in-game:
    lua broker_main.lua
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

  local watch = ArrayWatch.new({
    config = Config,
    poll = MachinePoll.new({ config = Config, component = component }),
    circuit_manager = CircuitManager.new({ config = Config, component = component }),
    link = link,
    reply_to = Config.orchestrator_address ~= "" and Config.orchestrator_address or nil,
    log = print,
    now = computer.uptime,
  })

  local interval = Config.tick_interval or 1.0
  print(string.format("[Broker] online — array watch mode, subnet=%s, listen %d → %d, orch=%s",
    Config.subnet_id, listen_port, orch_port, Config.orchestrator_address or "(none)"))

  while true do
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
