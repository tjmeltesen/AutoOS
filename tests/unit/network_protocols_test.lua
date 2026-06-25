#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/network_protocols_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "shared" .. sep .. "?.lua",
  package.path,
}, ";")

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

io.write("\n" .. bold("Network Protocols Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- BROKER_HEALTH
do
  local msg = Protocols.broker_health("subnet-1", "machine-01", "WORKING", "all good")
  local pkt, err = Protocols.parse(msg)
  check("BROKER_HEALTH parse ok", pkt ~= nil, err)
  check("BROKER_HEALTH kind", pkt.kind == "BROKER_HEALTH")
  check("BROKER_HEALTH subnet_id", pkt.subnet_id == "subnet-1")
  check("BROKER_HEALTH machine_id", pkt.machine_id == "machine-01")
  check("BROKER_HEALTH state", pkt.state == "WORKING")
  check("BROKER_HEALTH detail", pkt.detail == "all good")
end

-- BROKER_EVENT
do
  local msg = Protocols.broker_event("subnet-1", "job_complete", "item:ingotIron", 144000, "job_042")
  local pkt = Protocols.parse(msg)
  check("BROKER_EVENT kind", pkt.kind == "BROKER_EVENT")
  check("BROKER_EVENT event", pkt.event == "job_complete")
  check("BROKER_EVENT volume", pkt.volume == 144000)
  check("BROKER_EVENT job_id", pkt.job_id == "job_042")
end

-- DISPATCH_JOB
do
  local msg = Protocols.dispatch_job("job_001", 42, "item:ingotIron", 144000, "subnet-1", "batch")
  local pkt = Protocols.parse(msg)
  check("DISPATCH_JOB kind", pkt.kind == "DISPATCH_JOB")
  check("DISPATCH_JOB recipe_uid", pkt.recipe_uid == 42)
  check("DISPATCH_JOB volume_mB", pkt.volume_mB == 144000)
  check("DISPATCH_JOB mode", pkt.mode == "batch")
end

-- BROKER_STATUS
do
  local msg = Protocols.broker_status("subnet-1", "job_001", "running", "phase 3")
  local pkt = Protocols.parse(msg)
  check("BROKER_STATUS kind", pkt.kind == "BROKER_STATUS")
  check("BROKER_STATUS phase", pkt.phase == "running")
  check("BROKER_STATUS detail", pkt.detail == "phase 3")
end

-- CRAFT_ACK
do
  local msg = Protocols.craft_ack("job_001", "subnet-1")
  local pkt = Protocols.parse(msg)
  check("CRAFT_ACK kind", pkt.kind == "CRAFT_ACK")
  check("CRAFT_ACK job_id", pkt.job_id == "job_001")
end

-- CRAFT_DONE
do
  local msg = Protocols.craft_done("job_001", "subnet-1")
  local pkt = Protocols.parse(msg)
  check("CRAFT_DONE kind", pkt.kind == "CRAFT_DONE")
end

-- CRAFT_FAIL
do
  local msg = Protocols.craft_fail("job_001", "subnet-1", "missing resources")
  local pkt = Protocols.parse(msg)
  check("CRAFT_FAIL kind", pkt.kind == "CRAFT_FAIL")
  check("CRAFT_FAIL detail", pkt.detail == "missing resources")
end

-- TRIGGER_CRAFT
do
  local msg = Protocols.trigger_craft("job_001", "item:ingotIron", 144000, "subnet-1")
  local pkt = Protocols.parse(msg)
  check("TRIGGER_CRAFT kind", pkt.kind == "TRIGGER_CRAFT")
  check("TRIGGER_CRAFT volume_mB", pkt.volume_mB == 144000)
end

-- SUBNET_DELIVERY
do
  local msg = Protocols.subnet_delivery("subnet-1", "job_001", 42, "item:ingotIron", 144000, "broker-1")
  local pkt = Protocols.parse(msg)
  check("SUBNET_DELIVERY kind", pkt.kind == "SUBNET_DELIVERY")
  check("SUBNET_DELIVERY source", pkt.source == "broker-1")
end

-- DELIVERY_ACK
do
  local msg = Protocols.delivery_ack("job_001", "subnet-1")
  local pkt = Protocols.parse(msg)
  check("DELIVERY_ACK kind", pkt.kind == "DELIVERY_ACK")
end

-- Pipe sanitization
do
  local msg = Protocols.broker_health("subnet|evil", "mach|ine", "WORKING", "pipe|test")
  local pkt = Protocols.parse(msg)
  check("pipe is sanitized in subnet_id", pkt.subnet_id == "subnet/evil")
  check("pipe is sanitized in machine_id", pkt.machine_id == "mach/ine")
  check("pipe is sanitized in detail", pkt.detail == "pipe/test")
end

-- Unknown kind
do
  local pkt, err = Protocols.parse("UNKNOWN|a|b|c")
  check("unknown kind returns nil", pkt == nil, err)
end

-- Invalid input
do
  local pkt, err = Protocols.parse(nil)
  check("nil input returns nil", pkt == nil)
  local pkt2, err2 = Protocols.parse("")
  check("empty string returns nil", pkt2 == nil)
  local pkt3, err3 = Protocols.parse(42)
  check("non-string returns nil", pkt3 == nil)
end

-- Round-trip: all message kinds
do
  local function roundtrip(encoder, msg_name, ...)
    local msg = encoder(...)
    local pkt = Protocols.parse(msg)
    return pkt ~= nil and pkt.kind == msg_name
  end

  check("round-trip BROKER_HEALTH", roundtrip(Protocols.broker_health, "BROKER_HEALTH", "s", "m", "s", "d"))
  check("round-trip DISPATCH_JOB", roundtrip(Protocols.dispatch_job, "DISPATCH_JOB", "j", 1, "k", 100, "s"))
  check("round-trip BROKER_STATUS", roundtrip(Protocols.broker_status, "BROKER_STATUS", "s", "j", "p", "d"))
  check("round-trip BROKER_EVENT", roundtrip(Protocols.broker_event, "BROKER_EVENT", "s", "e", "l", 1, "j"))
  check("round-trip CRAFT_ACK", roundtrip(Protocols.craft_ack, "CRAFT_ACK", "j", "s"))
  check("round-trip CRAFT_DONE", roundtrip(Protocols.craft_done, "CRAFT_DONE", "j", "s"))
  check("round-trip CRAFT_FAIL", roundtrip(Protocols.craft_fail, "CRAFT_FAIL", "j", "s", "d"))
  check("round-trip TRIGGER_CRAFT", roundtrip(Protocols.trigger_craft, "TRIGGER_CRAFT", "j", "l", 1, "s"))
  check("round-trip SUBNET_DELIVERY", roundtrip(Protocols.subnet_delivery, "SUBNET_DELIVERY", "s", "j", 1, "k", 1, "src"))
  check("round-trip DELIVERY_ACK", roundtrip(Protocols.delivery_ack, "DELIVERY_ACK", "j", "s"))
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Network Protocols result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
