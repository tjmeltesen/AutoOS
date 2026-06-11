--[[
  Universal Craft Brokers — broker in-game boot template.

  Deploy under /home/universal/ on each broker PC (subnet ME net).
  Requires: Network Card, ME Interface, gt_machine adapter(s) per multi.
]]

local universal_root = "/home/universal"
package.path = universal_root .. "/?.lua;" .. package.path

local component = require("component")
local computer = require("computer")
local event = require("event")

local Broker = require("broker.main")

local modem = component.modem
local me = component.me_interface or component.me_controller

modem_port = 4410
coordinator_addr = nil -- set after first coordinator message, or pin UUID below
-- coordinator_addr = "<coordinator-computer-uuid>"

broker_id = "dist_array_1"
grace_seconds = 15

-- Hardware capabilities only — products live in shared/recipe_registry.lua.
multis = {
  {
    id = "dist_tower_a",
    address = "<gt_machine-uuid>",
    capabilities = { "distillation_tower" },
    installed_tools = { "Circuit24", "TowerMold" },
  },
  {
    id = "dist_tower_b",
    address = "<other-gt_machine-uuid>",
    capabilities = { "distillation_tower" },
    installed_tools = { "Circuit25", "TowerMold" },
  },
}

local broker = Broker.new({
  config = { broker_id = broker_id, multis = multis },
  component = component,
  me = me,
  computer = computer,
  modem = modem,
  modem_port = modem_port,
  coordinator_addr = coordinator_addr,
  grace_seconds = grace_seconds,
  log = print,
})

broker:open_modem()
print("[Universal] Broker " .. broker_id .. " started on port " .. tostring(modem_port))

while true do
  local deadline = computer.uptime() + 0.5
  repeat
    local ev = { event.pull(0.5) }
    if ev[1] == "modem_message" then
      broker:run_step(table.unpack(ev))
    end
  until computer.uptime() >= deadline
  broker:tick()
end
