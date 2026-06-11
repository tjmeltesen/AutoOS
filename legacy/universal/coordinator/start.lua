--[[
  Universal Craft Brokers — coordinator in-game boot template.

  Deploy under /home/universal/ on the coordinator PC (main ME net).
  Requires: Network Card, ME Interface or Controller adapter.
]]

local universal_root = "/home/universal"
package.path = universal_root .. "/?.lua;" .. package.path

local component = require("component")
local computer = require("computer")
local event = require("event")

local Coordinator = require("coordinator.main")

local modem = component.modem
local me = component.me_interface or component.me_controller

modem_port = 4410

-- Modem addresses only — NOT product→broker routing.
brokers = {
  { id = "dist_array_1", address = "<broker-computer-uuid>" },
  { id = "chem_array_1", address = "<other-broker-uuid>" },
}

-- Product-only targets (no broker_id, no machine_type).
targets = {
  { label = "Benzene",      kind = "fluid", low = 8000,  high = 32000, max_craft = 16000 },
  { label = "Toluene",      kind = "fluid", low = 4000,  high = 16000, max_craft = 8000 },
  { label = "SulfuricAcid", kind = "fluid", low = 16000, high = 64000, max_craft = 32000 },
}

local coord = Coordinator.new({
  me = me,
  computer = computer,
  event = event,
  modem = modem,
  modem_port = modem_port,
  brokers = brokers,
  targets = targets,
  tick_interval = 0.5,
  ack_timeout = 30,
  log = print,
})

coord:open_modem()
coord:ping_brokers()

print("[Universal] Coordinator started on port " .. tostring(modem_port))

while true do
  local deadline = computer.uptime() + 0.5
  repeat
    local ev = { event.pull(0.5) }
    if ev[1] == "modem_message" then
      coord:run_step(table.unpack(ev))
    end
  until computer.uptime() >= deadline
  coord:tick()
end
