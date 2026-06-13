--[[
  AutoOS — Orchestrator OC entry point

  Wires real OC hardware (modem + MAIN net ME adapter) to the orchestrator FSM.

  Run in-game:
    loadfile("/home/orchestrator/orchestrator_main.lua")().run()
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/orchestrator"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("orchestrator_config")
local Registry = require("ae_recipe_registry")
local MainNetCache = require("main_net_cache")
local Orchestrator = require("orchestrator")
local Protocols = require("network_protocols")

local OrchestratorMain = {}

local function make_link(modem, port)
  modem.open(port)
  return {
    send = function(_, addr, msg) modem.send(addr, port, msg) end,
    broadcast = function(_, msg) modem.broadcast(port, msg) end,
  }
end

function OrchestratorMain.build()
  local ok, err = Config.validate(Config)
  if not ok then return nil, "config invalid: " .. tostring(err) end

  local component = require("component")
  if not component.isAvailable("modem") then
    return nil, "no modem component — orchestrator needs a network card"
  end
  local modem = component.modem
  local port = Config.modem_port or Protocols.PORT_DEFAULT

  local registry = Registry.new({ config = Config })
  if (Config.orchestrator or {}).registry_persist then
    registry:load()
  end
  local seeded, seed_err = registry:seed_from_config()
  if not seeded then return nil, "registry seed: " .. tostring(seed_err) end
  local valid, verr = registry:validate()
  if not valid then return nil, "registry invalid: " .. tostring(verr) end

  local me = Config.me_address ~= "" and component.proxy(Config.me_address) or nil
  local main_net_cache = MainNetCache.new({ config = Config, component = component, me = me })

  local orch = Orchestrator.new({
    config = Config,
    registry = registry,
    main_net_cache = main_net_cache,
    me = me,
    link = make_link(modem, port),
    now = function() return require("computer").uptime() end,
    log = print,
  })
  return orch, nil, { registry = registry, port = port }
end

function OrchestratorMain.run()
  local orch, err, info = OrchestratorMain.build()
  if not orch then
    print("[Orchestrator] start FAILED: " .. tostring(err))
    return
  end
  local event = require("event")
  local interval = (Config.orchestrator or {}).tick_interval or 1.0

  print(string.format("[Orchestrator] online — main net, subnet '%s', port %d, %d recipe(s)",
    Config.subnet_id, info.port, (function()
      local n = 0; for _ in pairs(info.registry.entries) do n = n + 1 end; return n
    end)()))

  while true do
    local id, _, from, _, _, message = event.pull(interval, "modem_message")
    if id == "modem_message" then
      orch:on_message(from, message)
    else
      orch:tick()
    end
  end
end

return OrchestratorMain
