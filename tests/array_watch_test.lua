#!/usr/bin/env lua
--[[
  AutoOS — Array Watch desktop tests

  Run: lua55 tests\array_watch_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/array_watch_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "shared" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "orchestrator" .. sep .. "?.lua",
  package.path,
}, ";")

local Protocols = require("network_protocols")
local ArrayWatch = require("array_watch")
local Orchestrator = require("orchestrator")

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

io.write("\n" .. bold("AutoOS Array Watch Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- Fault shutdown + health telemetry -------------------------------------------
do
  local sent = {}
  local proxy = {
    setWorkAllowed = function(v) sent[#sent + 1] = { api = "setWorkAllowed", value = v } end,
  }
  local poll = {
    get_proxy = function(_, id) if id == "machine_01" then return proxy end return nil end,
    poll_all = function()
      return {
        machine_01 = { available = true, healthy = false, maintenance_fault = true, fault_message = "Problems: 1", active = true, has_work = true },
      }
    end,
  }
  local link_out = {}
  local watch = ArrayWatch.new({
    config = { subnet_id = "sub", machines = { { id = "machine_01" } } },
    poll = poll,
    circuit_manager = { recover_circuit = function() return true end },
    link = { send = function(_, _, msg) link_out[#link_out + 1] = msg end },
    reply_to = "orch-1",
    now = function() return 11 end,
  })
  watch:tick()

  check("fault triggers setWorkAllowed(false)", sent[1] and sent[1].value == false)
  local saw_health = false
  local saw_fault_event = false
  for _, msg in ipairs(link_out) do
    local p = Protocols.parse(msg)
    if p and p.kind == Protocols.KIND.BROKER_HEALTH and p.state == "fault" then saw_health = true end
    if p and p.kind == Protocols.KIND.BROKER_EVENT and p.event == Protocols.EVENT.MACHINE_FAULT then saw_fault_event = true end
  end
  check("fault emits BROKER_HEALTH", saw_health)
  check("fault emits BROKER_EVENT machine_fault", saw_fault_event)
end

-- Processing complete recover (active true -> false) ---------------------------
do
  local tick_n = 0
  local recovered = 0
  local msgs = {}
  local poll = {
    get_proxy = function() return nil end,
    poll_all = function()
      tick_n = tick_n + 1
      if tick_n == 1 then
        return { machine_01 = { available = true, healthy = true, maintenance_fault = false, active = true, has_work = true } }
      end
      return { machine_01 = { available = true, healthy = true, maintenance_fault = false, active = false, has_work = false } }
    end,
  }
  local watch = ArrayWatch.new({
    config = { subnet_id = "sub", machines = { { id = "machine_01" } } },
    poll = poll,
    circuit_manager = { recover_circuit = function() recovered = recovered + 1; return true end },
    link = { send = function(_, _, msg) msgs[#msgs + 1] = msg end },
    reply_to = "orch-1",
    now = function() return 12 + tick_n end,
  })

  watch:tick()
  watch:tick()
  check("processing-complete edge triggers one recover", recovered == 1, recovered)

  local saw_recovered = false
  for _, msg in ipairs(msgs) do
    local p = Protocols.parse(msg)
    if p and p.kind == Protocols.KIND.BROKER_EVENT and p.event == Protocols.EVENT.CIRCUIT_RECOVERED then
      saw_recovered = true
    end
  end
  check("recover emits circuit_recovered event", saw_recovered)
end

-- No recover when machine is idle from startup ---------------------------------
do
  local recovered = 0
  local poll = {
    get_proxy = function() return nil end,
    poll_all = function()
      return { machine_01 = { available = true, healthy = true, maintenance_fault = false, active = false, has_work = false } }
    end,
  }
  local watch = ArrayWatch.new({
    config = { subnet_id = "sub", machines = { { id = "machine_01" } } },
    poll = poll,
    circuit_manager = { recover_circuit = function() recovered = recovered + 1; return true end },
    now = function() return 20 end,
  })

  watch:tick()
  watch:tick()
  check("startup idle does not recover", recovered == 0, recovered)
end

-- No recover when has_work=true but not active ---------------------------------
do
  local recovered = 0
  local poll = {
    get_proxy = function() return nil end,
    poll_all = function()
      return { machine_01 = { available = true, healthy = true, maintenance_fault = false, active = false, has_work = true } }
    end,
  }
  local watch = ArrayWatch.new({
    config = { subnet_id = "sub", machines = { { id = "machine_01" } } },
    poll = poll,
    circuit_manager = { recover_circuit = function() recovered = recovered + 1; return true end },
    now = function() return 21 end,
  })

  watch:tick()
  watch:tick()
  check("queued/waiting does not recover", recovered == 0, recovered)
end

-- Orchestrator aggregator -----------------------------------------------------
do
  local out = {}
  local orch = Orchestrator.new({
    config = { subnet_id = "sub" },
    link = { send = function(_, addr, msg) out[#out + 1] = { addr = addr, msg = msg } end, broadcast = function() end },
    now = function() return 42 end,
  })

  orch:on_message("broker-1", Protocols.broker_health("sub", "machine_01", "idle", "ok"))
  orch:on_message("broker-1", Protocols.broker_event("sub", Protocols.EVENT.CIRCUIT_RECOVERED, "machine_01", 0, "ok"))

  local row = orch.brokers.sub
  check("orchestrator stores broker row", row ~= nil)
  check("orchestrator stores lane state", row and row.lanes.machine_01 and row.lanes.machine_01.state == "idle")
  check("orchestrator stores last event", row and row.last_event and row.last_event.event == Protocols.EVENT.CIRCUIT_RECOVERED)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Array watch result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
