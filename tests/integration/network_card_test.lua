#!/usr/bin/env lua
-- Network card integration: two-node modem hub, encode→send→receive→decode

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/integration/network_card_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "shared" .. sep .. "?.lua",
  package.path,
}, ";")

local MockNetwork = require("mock_network")
local Protocols = require("network_protocols")

local ESC = string.char(27)
local function color(c, t) return ESC .. "[" .. c .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write("  -  " .. tostring(detail)) end
  io.write("\n")
end

io.write("\n" .. bold("Network Card Integration Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local net = MockNetwork.new()
  local node_a = net:node("broker-01")
  local node_b = net:node("orchestrator")

  check("nodes created", node_a ~= nil and node_b ~= nil)
  check("nodes have send", type(node_a.send) == "function")
  check("nodes have broadcast", type(node_a.broadcast) == "function")
end

do
  -- Single message: encode -> send -> deliver -> drain -> decode
  local net = MockNetwork.new()
  local broker = net:node("broker-01")
  net:node("orchestrator")

  local msg = Protocols.broker_health("subnet-1", "machine-01", "WORKING", "nominal")
  broker:send("orchestrator", msg)

  -- Verify message is queued before delivery
  check("message queued before deliver", #net.queue == 1)

  net:deliver()

  -- After deliver, queue is consumed
  check("queue consumed after deliver", #net.queue == 0)

  local inbox = net:drain("orchestrator")
  check("inbox has one message", #inbox == 1)

  if #inbox >= 1 then
    check("from broker-01", inbox[1].from == "broker-01")
    local pkt, err = Protocols.parse(inbox[1].msg)
    check("parse ok", pkt ~= nil, err)
  end
end

do
  -- All message kinds round-trip through network
  local net = MockNetwork.new()
  local a = net:node("a")
  net:node("b")

  local msgs = {
    Protocols.broker_health("s1", "m1", "IDLE", "ok"),
    Protocols.dispatch_job("j1", 1, "key", 1000, "s1"),
    Protocols.broker_status("s1", "j1", "running", "phase 3"),
    Protocols.broker_event("s1", "job_complete", "item:ingotIron", 144000, "j1"),
    Protocols.craft_ack("j1", "s1"),
    Protocols.craft_done("j1", "s1"),
    Protocols.craft_fail("j1", "s1", "no resources"),
    Protocols.trigger_craft("j1", "item:ingotIron", 144000, "s1"),
    Protocols.subnet_delivery("s1", "j1", 1, "key", 1000, "src"),
    Protocols.delivery_ack("j1", "s1"),
  }

  for i, msg in ipairs(msgs) do
    a:send("b", msg)
    net:deliver()
    local inbox = net:drain("b")
    check("msg " .. i .. " delivered", #inbox == 1)
    local pkt, err = Protocols.parse(inbox[1].msg)
    check("msg " .. i .. " parses", pkt ~= nil, err)
  end
end

do
  -- Broadcast reaches all nodes except sender
  local net = MockNetwork.new()
  local a = net:node("a")
  net:node("b")
  local c = net:node("c")

  a:broadcast("hello_all")
  net:deliver()

  local inbox_b = net:drain("b")
  local inbox_c = net:drain("c")
  local inbox_a = net:drain("a")

  check("broadcast reaches b", #inbox_b == 1)
  check("broadcast reaches c", #inbox_c == 1)
  check("broadcast not received by sender", #inbox_a == 0)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Network card result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
