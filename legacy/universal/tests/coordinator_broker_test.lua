#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "universal/tests/coordinator_broker_test.lua"
local tests_dir = script:match("^(.*)[/\\]") or "universal/tests"
local universal_root = tests_dir .. sep .. ".."
local project_root = universal_root .. sep .. ".."
package.path = table.concat({
  universal_root .. sep .. "?.lua",
  tests_dir .. sep .. "?.lua",
  project_root .. sep .. "?.lua",
  package.path,
}, ";")

local H = require("test_harness")
local MockModem = require("mock_modem")
local Protocol = require("shared.protocol")
local Coordinator = require("coordinator.main")
local Broker = require("broker.main")

H.summary("Universal — coordinator + broker integration")

local COORD_ADDR = "coord-001"
local BROKER_ADDR = "broker-dist-001"
local PORT = 4410

local function make_machine_mock(opts)
  opts = opts or {}
  local state = {
    work_allowed = true,
    active = opts.active or false,
    has_work = opts.has_work or false,
    sensor = opts.sensor or { "Running.", "Problems: 0" },
    craft_triggers_active = opts.craft_triggers_active ~= false,
  }
  return {
    state = state,
    isWorkAllowed = function() return state.work_allowed end,
    setWorkAllowed = function(v)
      state.work_allowed = v
      if not v then state.active = false; state.has_work = false end
      return 1
    end,
    isMachineActive = function() return state.active end,
    hasWork = function() return state.has_work end,
    getSensorInformation = function() return state.sensor end,
  }
end

local function make_me_mock()
  local state = { craftables = { Benzene = true }, craft_done = false, jobs = {} }
  return {
    state = state,
    getCraftables = function(filter)
      if filter.label and state.craftables[filter.label] then
        return {{
          request = function(amount)
            state.craft_done = false
            state.last_amount = amount
            local job = {
              isDone = function() return state.craft_done end,
              hasFailed = function() return false end,
              isCanceled = function() return false end,
              isComputing = function() return not state.craft_done end,
            }
            state.jobs[filter.label] = job
            if state.machine and state.machine.state then
              state.machine.state.active = true
              state.machine.state.has_work = true
            end
            return job
          end,
        }}
      end
      return {}
    end,
    getFluidsInNetwork = function()
      return {{ label = "Benzene", amount = state.benzene or 5000 }}
    end,
    getItemsInNetwork = function() return {} end,
    set_benzene = function(n) state.benzene = n end,
    finish_craft = function()
      state.craft_done = true
    end,
    set_machine = function(m) state.machine = m end,
  }
end

-- Wire modem between coordinator and broker.
local modem_coord = { open = function() end, sent = {} }
local modem_broker = { open = function() end, sent = {} }

-- OC modem.send(addr, port, payload) — dot call, no implicit self.
local function relay(from_modem, to_handler)
  from_modem.send = function(target, port, payload)
    from_modem.sent[#from_modem.sent + 1] = { to = target, port = port, payload = payload }
    to_handler(target, port, payload)
  end
end

local tower_a = make_machine_mock()
local tower_b = make_machine_mock()
local proxies = {
  ["addr-tower-a"] = tower_a,
  ["addr-tower-b"] = tower_b,
}
local component_lib = {
  proxy = function(addr, _) return proxies[addr] end,
}

local me_broker = make_me_mock()
me_broker.set_machine(tower_a)

local comp = { clock = 0 }
function comp.uptime()
  local t = comp.clock
  comp.clock = comp.clock + 0.5
  return t
end
function comp.advance(sec)
  comp.clock = comp.clock + (sec or 0)
end
local computer = comp

local coord_modem_queue = {}
local coord_last_msg

local broker = Broker.new({
  config = {
    broker_id = "dist_array_1",
    multis = {
      { id = "dist_tower_a", address = "addr-tower-a",
        capabilities = { "distillation_tower" },
        installed_tools = { "Circuit24", "TowerMold" } },
      { id = "dist_tower_b", address = "addr-tower-b",
        capabilities = { "distillation_tower" },
        installed_tools = { "Circuit25", "TowerMold" } },
    },
  },
  component = component_lib,
  me = me_broker,
  computer = computer,
  modem = modem_broker,
  modem_port = PORT,
  coordinator_addr = COORD_ADDR,
  grace_seconds = 15,
  log = function() end,
})

relay(modem_coord, function(target, port, payload)
  if target == BROKER_ADDR then
    broker:run_step("modem_message", BROKER_ADDR, COORD_ADDR, port, 0, payload)
  end
end)

relay(modem_broker, function(target, port, payload)
  if target == COORD_ADDR then
    coord_last_msg = payload
    coord_modem_queue[#coord_modem_queue + 1] = {
      "modem_message", COORD_ADDR, BROKER_ADDR, port, 0, payload,
    }
  end
end)

local coord = Coordinator.new({
  me = me_broker,
  computer = computer,
  modem = modem_coord,
  modem_port = PORT,
  brokers = { { id = "dist_array_1", address = BROKER_ADDR } },
  targets = {
    { label = "Benzene", kind = "fluid", low = 8000, high = 32000, max_craft = 16000 },
  },
  ack_timeout = 30,
  log = function() end,
})

-- Low stock triggers craft_req broadcast.
me_broker.set_benzene(5000)
local tick1 = coord:tick()
H.check("coordinator emits need", #tick1.needs == 1 and tick1.needs[1].label == "Benzene")
H.check("craft_req broadcast", #modem_coord.sent >= 1)
H.check("craft_req payload",
  modem_coord.sent[1].payload:find("^craft_req|") ~= nil)

-- Broker accepts Benzene -> Tower A.
H.check("broker ack sent", coord_modem_queue[1] ~= nil)
local ack_decoded = Protocol.decode(coord_modem_queue[1][6])
local ack = Protocol.parse_craft_ack(ack_decoded.fields)
H.check("ack machine Tower A", ack and ack.machine_id == "dist_tower_a")

coord:run_step(table.unpack(coord_modem_queue[1]))
H.check("coordinator job running",
  coord.broker_client.jobs[ack.job_id].state == "running")

-- AE completes; machine still busy.
me_broker.finish_craft()
tower_a.state.active = true
tower_a.state.has_work = true
broker:tick()
H.check("not done while machine busy", #modem_broker.sent == 0 or
  not modem_broker.sent[#modem_broker.sent].payload:find("^craft_done"))

-- Machine idle; grace not elapsed.
tower_a.state.active = false
tower_a.state.has_work = false
broker:tick()
H.check("not done during grace", coord_modem_queue[2] == nil)

comp.advance(16)
broker:tick()
H.check("craft_done after grace", coord_modem_queue[2] ~= nil)
local done_msg = coord_modem_queue[2][6]
H.check("done payload", done_msg:find("^craft_done|") ~= nil)

coord:run_step(table.unpack(coord_modem_queue[2]))
H.check("in_flight cleared", coord.broker_client:label_in_flight("Benzene") == false)

-- Toluene routes to Tower B when A lacks Circuit25.
tower_b.state.active = false
tower_b.state.has_work = false
tower_a.state.active = true
modem_coord.sent = {}
coord_modem_queue = {}

local broker2 = Broker.new({
  config = {
    broker_id = "dist_array_1",
    multis = {
      { id = "dist_tower_a", address = "addr-tower-a",
        capabilities = { "distillation_tower" },
        installed_tools = { "Circuit24", "TowerMold" } },
      { id = "dist_tower_b", address = "addr-tower-b",
        capabilities = { "distillation_tower" },
        installed_tools = { "Circuit25", "TowerMold" } },
    },
  },
  component = component_lib,
  me = me_broker,
  computer = computer,
  modem = modem_broker,
  modem_port = PORT,
  coordinator_addr = COORD_ADDR,
  grace_seconds = 1,
  log = function() end,
})

local Dispatcher = require("broker.dispatcher")
local id = Dispatcher.pick("Toluene", broker2.registry:list(), {
  machines = {
    dist_tower_a = { available = true, active = false, has_work = false, maintenance_fault = false },
    dist_tower_b = { available = true, active = false, has_work = false, maintenance_fault = false },
  },
})
H.check("Toluene picks Tower B", id == "dist_tower_b")

os.exit(H.report() and 0 or 1)
