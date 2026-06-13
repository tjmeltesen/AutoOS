--[[
  AutoOS — Orchestrator modem link test (one-shot)

  Sends a DISPATCH_JOB to the broker and prints any replies on the orchestrator
  listen port. Use this instead of a bare modem.send() in the REPL — send() never
  prints anything by itself.

  Prerequisites:
    * broker PC running: lua broker_main.lua
    * orchestrator_config.lua broker_address set to broker modem UUID
    * wireless network cards on both PCs (or linked cards in range)

  Run on manager PC:
    lua link_test.lua
    -- or: loadfile("/home/orchestrator/link_test.lua")()
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/orchestrator"
package.path = here .. sep .. "?.lua;" .. package.path

local component = require("component")
local event = require("event")
local computer = require("computer")
local Config = require("orchestrator_config")
local P = require("network_protocols")

if not component.isAvailable("modem") then
  print("[link_test] no modem component")
  return
end

local m = component.modem
local broker = Config.broker_address
if not broker or broker == "" then
  print("[link_test] broker_address empty — set it in orchestrator_config.lua")
  return
end

local listen = Config.modem_port or P.PORT_DEFAULT
local broker_port = Config.broker_modem_port or listen
m.open(listen)
if broker_port ~= listen then m.open(broker_port) end

local msg = P.dispatch_job("link-test", 257, "polyethylene", 3000, Config.subnet_id, "batch")
print("[link_test] wireless modem:", m.isWireless())
print("[link_test] send ->", broker, "port", broker_port)
print("[link_test] wire:", msg)
local sent = m.send(broker, broker_port, msg)
print("[link_test] modem.send returned:", sent)

print("[link_test] listening on port", listen, "for replies (15s)...")
print("[link_test] (broker should print on worker screen if broker_main.lua is running)")

local deadline = computer.uptime() + 15
while computer.uptime() < deadline do
  local ev, _, from, port, _, message = event.pull(1, "modem_message")
  if ev == "modem_message" then
    print(string.format("[link_test] RX from %s port %s: %s", from, port, message))
  end
end
print("[link_test] done")
