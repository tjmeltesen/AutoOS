--[[
  AutoOS — Orchestrator OC entry point (health aggregator)

  Listens for broker health/event telemetry and keeps broker snapshots.

  Run in-game:
    lua orchestrator_main.lua
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/orchestrator"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("orchestrator_config")
local Orchestrator = require("orchestrator")
local Protocols = require("network_protocols")

local OrchestratorMain = {}

function OrchestratorMain.build()
  local ok, err = Config.validate(Config)
  if not ok then return nil, "config invalid: " .. tostring(err) end

  local component = require("component")
  if not component.isAvailable("modem") then
    return nil, "no modem component — orchestrator needs a network card"
  end

  local modem = component.modem
  local listen_port = Config.modem_port or Protocols.PORT_DEFAULT
  local broker_port = Config.broker_modem_port or listen_port
  modem.open(listen_port)
  if broker_port ~= listen_port then modem.open(broker_port) end

  local orch = Orchestrator.new({
    config = Config,
    link = {
      send = function(_, addr, msg) modem.send(addr, broker_port, msg) end,
      broadcast = function(_, msg) modem.broadcast(listen_port, msg) end,
    },
    now = function() return require("computer").uptime() end,
    log = print,
  })

  return orch, nil, { listen_port = listen_port, broker_port = broker_port }
end

function OrchestratorMain.run()
  local orch, err, info = OrchestratorMain.build()
  if not orch then
    print("[Orchestrator] start FAILED: " .. tostring(err))
    return false
  end

  local event = require("event")
  local interval = (Config.orchestrator or {}).tick_interval or 1.0
  print(string.format("[Orchestrator] online — health aggregator listen %d broker_port %d",
    info.listen_port, info.broker_port))

  while true do
    local id, _, from, _, _, message = event.pull(interval, "modem_message")
    if id == "modem_message" then
      orch:on_message(from, message)
    else
      orch:tick()
    end
  end
end

local function is_direct_run()
  if arg and arg[0] then
    local script = arg[0]:gsub("\\", "/")
    local name = script:match("([^/]+)$") or script
    if name == "orchestrator_main.lua" or name:find("orchestrator_main", 1, true) then return true end
  end
  local ok, proc = pcall(require, "process")
  if ok and proc and proc.info then
    local path = proc.info()
    if type(path) == "string" and path:find("orchestrator_main", 1, true) then return true end
  end
  return false
end

if is_direct_run() then
  print("[Orchestrator] starting...")
  local ok, err = xpcall(OrchestratorMain.run, debug.traceback)
  if not ok then print("[Orchestrator] FATAL:\n" .. tostring(err)) end
end

return OrchestratorMain
