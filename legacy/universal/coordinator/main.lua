--[[
  Universal Craft Brokers — coordinator main loop (main ME net).
]]

local StockWatcher = require("coordinator.stock_watcher")
local BrokerClient = require("coordinator.broker_client")

local Coordinator = {}
Coordinator.__index = Coordinator

function Coordinator.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Coordinator)
  self.me = deps.me
  self.computer = deps.computer
  self.event = deps.event
  self.watcher = StockWatcher.new(deps.targets, deps.watcher_opts)
  self.broker_client = BrokerClient.new({
    modem = deps.modem,
    modem_port = deps.modem_port,
    brokers = deps.brokers,
    computer = deps.computer,
    log = deps.log,
  })
  self.tick_interval = deps.tick_interval or 0.5
  self.ack_timeout = deps.ack_timeout or 30
  self.cache = { stock = {} }
  self.log = deps.log or function() end
  return self
end

function Coordinator:open_modem()
  self.broker_client:open_modem()
end

function Coordinator:poll_stock()
  local stock = self.cache.stock
  for k in pairs(stock) do
    stock[k] = nil
  end

  if not self.me then
    return self.cache
  end

  for _, t in ipairs(self.watcher.targets) do
    local count
    if t.kind == "fluid" and self.me.getFluidsInNetwork then
      for _, stack in ipairs(self.me.getFluidsInNetwork()) do
        if stack.label == t.label then
          count = stack.amount
          break
        end
      end
    elseif self.me.getItemsInNetwork then
      local items = self.me.getItemsInNetwork({ label = t.label })
      if items[1] then
        count = items[1].size
      end
    end
    if count ~= nil then
      stock[t.label] = count
    end
  end

  return self.cache
end

function Coordinator:tick()
  self:poll_stock()
  self.broker_client:expire_pending(self.ack_timeout)
  local in_flight = self.broker_client:get_in_flight_labels()
  local needs = self.watcher:evaluate(self.cache, in_flight)

  for _, need in ipairs(needs) do
    self.broker_client:broadcast_craft(need.label, need.amount, need.kind)
  end

  return { cache = self.cache, needs = needs }
end

function Coordinator:run_step(event_name, ...)
  if event_name == "modem_message" then
    return self.broker_client:handle_message(...)
  end
  return self:tick()
end

function Coordinator:ping_brokers()
  self.broker_client:ping_all("coordinator")
end

return Coordinator
