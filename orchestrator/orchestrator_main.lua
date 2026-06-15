--[[
  AutoOS — Orchestrator OC entry point

  Coordinator: listens for SUBNET_DELIVERY / BROKER_STATUS from the broker.
  The broker watches subnet ME and runs lanes — not this PC.

  Run in-game:
    lua orchestrator_main.lua
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/orchestrator"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("orchestrator_config")
local Registry = require("ae_recipe_registry")
local Orchestrator = require("orchestrator")
local Protocols = require("network_protocols")

local OrchestratorMain = {}

local function scan_enabled(cfg)
  local o = cfg.orchestrator or {}
  return o.pattern_scan_enabled ~= false
end

local function maybe_scan(orch, deps)
  local cfg = deps.config
  local o = cfg.orchestrator or {}
  if not scan_enabled(cfg) or not deps.me or not deps.registry then return end
  local interval = o.pattern_scan_interval_s or 600
  local computer = require("computer")
  local now = computer.uptime()
  if now - (deps._last_scan or 0) < interval then return end
  deps._last_scan = now

  local RecipeScanner = require("recipe_scanner")
  local added, updated = RecipeScanner.scan(deps.me, deps.registry, {
    config = cfg, log = deps.log or print, now = now,
  })
  if added > 0 or updated > 0 then
    (deps.log or print)(string.format("[Orchestrator] pattern scan: %d new, %d updated", added, updated))
    if o.registry_persist then deps.registry:save() end
  end
end

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

  local registry = Registry.new({ config = Config })
  if (Config.orchestrator or {}).registry_persist then
    registry:load()
  end
  local seeded, seed_err = registry:seed_from_config()
  if not seeded then return nil, "registry seed: " .. tostring(seed_err) end
  local valid, verr = registry:validate()
  if not valid then return nil, "registry invalid: " .. tostring(verr) end

  local me = nil
  if Config.me_address and Config.me_address ~= "" then
    me = component.proxy(Config.me_address)
  end
  if scan_enabled(Config) and me then
    local RecipeScanner = require("recipe_scanner")
    local added = RecipeScanner.scan(me, registry, {
      config = Config, log = print, now = require("computer").uptime(),
    })
    if added > 0 then
      print("[Orchestrator] boot scan: " .. added .. " new pattern(s)")
      if (Config.orchestrator or {}).registry_persist then registry:save() end
    end
  end

  local orch = Orchestrator.new({
    config = Config,
    registry = registry,
    link = {
      send = function(_, addr, msg) modem.send(addr, broker_port, msg) end,
      broadcast = function(_, msg) modem.broadcast(listen_port, msg) end,
    },
    now = function() return require("computer").uptime() end,
    log = print,
  })
  local deps = {
    config = Config, registry = registry, me = me,
    log = print, _last_scan = require("computer").uptime(),
  }
  return orch, nil, { registry = registry, listen_port = listen_port, broker_port = broker_port, deps = deps }
end

function OrchestratorMain.run()
  local orch, err, info = OrchestratorMain.build()
  if not orch then
    print("[Orchestrator] start FAILED: " .. tostring(err))
    return false
  end
  local event = require("event")
  local interval = (Config.orchestrator or {}).tick_interval or 1.0

  print(string.format("[Orchestrator] online — coordinator, listen %d, broker %s, %d recipe(s)",
    info.listen_port, Config.broker_address ~= "" and Config.broker_address or "(learn)",
    (function() local n = 0; for _ in pairs(info.registry.entries) do n = n + 1 end; return n end)()))
  print("[Orchestrator] broker watches subnet ME — place AE patterns on subnet storage")
  if scan_enabled(Config) and info.deps.me then
    print("[Orchestrator] main-net pattern scan enabled (optional registry parity)")
  end

  while true do
    local id, _, from, _, _, message = event.pull(interval, "modem_message")
    if id == "modem_message" then
      orch:on_message(from, message)
    else
      orch:tick()
      maybe_scan(orch, info.deps)
    end
  end
end

local function is_direct_run()
  if not arg or not arg[0] then return false end
  local script = arg[0]:gsub("\\", "/")
  local name = script:match("([^/]+)$") or script
  return name == "orchestrator_main.lua" or name:find("orchestrator_main", 1, true) ~= nil
end

if is_direct_run() then
  print("[Orchestrator] starting...")
  local ok, err = xpcall(OrchestratorMain.run, debug.traceback)
  if not ok then print("[Orchestrator] FATAL:\n" .. tostring(err)) end
end

return OrchestratorMain
