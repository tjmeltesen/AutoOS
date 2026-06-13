--[[
  AutoOS — Mock modem hub for Phase 3 desktop tests

  Models two OC modems sharing a port. Each node gets a `link` with
  :send(addr, msg) / :broadcast(msg). Messages queue on the hub; deliver()
  routes them into target inboxes. Tests then drain inboxes and feed them to
  Orchestrator:on_message / BrokerMain.on_message.
]]

local MockNetwork = {}
MockNetwork.__index = MockNetwork

function MockNetwork.new()
  return setmetatable({ nodes = {}, queue = {} }, MockNetwork)
end

--- Register a node by address. Returns a link bound to that node.
function MockNetwork:node(address)
  self.nodes[address] = self.nodes[address] or { address = address, inbox = {} }
  local hub = self
  return {
    address = address,
    send = function(_, to, msg)
      hub.queue[#hub.queue + 1] = { from = address, to = to, msg = msg }
    end,
    broadcast = function(_, msg)
      hub.queue[#hub.queue + 1] = { from = address, to = nil, msg = msg }
    end,
  }
end

--- Route all queued messages into target inboxes (broadcast → all but sender).
function MockNetwork:deliver()
  local pending = self.queue
  self.queue = {}
  for _, m in ipairs(pending) do
    if m.to then
      local node = self.nodes[m.to]
      if node then node.inbox[#node.inbox + 1] = { from = m.from, msg = m.msg } end
    else
      for addr, node in pairs(self.nodes) do
        if addr ~= m.from then node.inbox[#node.inbox + 1] = { from = m.from, msg = m.msg } end
      end
    end
  end
end

--- Drain and return a node's inbox (FIFO list of { from, msg }).
function MockNetwork:drain(address)
  local node = self.nodes[address]
  if not node then return {} end
  local got = node.inbox
  node.inbox = {}
  return got
end

return MockNetwork
