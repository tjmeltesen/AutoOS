--[[
  Universal Craft Brokers — in-memory modem for desktop tests.
]]

local MockModem = {}
MockModem.__index = MockModem

function MockModem.new(opts)
  opts = opts or {}
  local self = setmetatable({}, MockModem)
  self.nodes = opts.nodes or {}
  self.port = opts.port or 4410
  self.queue = {}
  self.sent = {}
  return self
end

function MockModem:register(address, handlers)
  self.nodes[address] = handlers or {}
end

function MockModem:open(port)
  self.open_port = port or self.port
end

function MockModem:send(target_addr, port, payload)
  self.sent[#self.sent + 1] = {
    to = target_addr,
    port = port,
    payload = payload,
  }
  local node = self.nodes[target_addr]
  if node and node.on_message then
    node.on_message(node.address, port, payload)
  end
end

function MockModem:broadcast(port, payload)
  for addr, node in pairs(self.nodes) do
    if node.on_message then
      node.on_message(node.address, port, payload)
    end
  end
end

-- Push modem_message events for event.pull simulation.
function MockModem:push(receiver, sender, port, distance, payload)
  self.queue[#self.queue + 1] = {
    "modem_message", receiver, sender, port, distance, payload,
  }
end

function MockModem:pull()
  if #self.queue > 0 then
    return table.unpack(self.queue[1])
  end
  return nil
end

function MockModem:drain_queue()
  local out = self.queue
  self.queue = {}
  return out
end

return MockModem
