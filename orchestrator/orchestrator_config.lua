--[[
  AutoOS — Orchestrator OC config (array watch mode)

  Orchestrator aggregates health from one or more broker OCs and presents status.
]]

local Config = {}

Config.subnet_id = "universal_chemical_mv_01"
Config.broker_address = "9f5e577e-5481-4fd2-97b4-c143f57b4565"
Config.modem_port = 105
Config.broker_modem_port = 106

Config.orchestrator = {
  tick_interval = 1.0,
}

function Config.validate(cfg)
  cfg = cfg or Config
  if type(cfg.subnet_id) ~= "string" or cfg.subnet_id == "" then
    return nil, "subnet_id required"
  end
  if type(cfg.modem_port) ~= "number" or cfg.modem_port < 1 then
    return nil, "modem_port must be a positive integer"
  end
  if cfg.broker_modem_port ~= nil and (type(cfg.broker_modem_port) ~= "number" or cfg.broker_modem_port < 1) then
    return nil, "broker_modem_port must be a positive integer"
  end
  if type(cfg.orchestrator) ~= "table" then
    return nil, "orchestrator settings table required"
  end
  return true
end

return Config
