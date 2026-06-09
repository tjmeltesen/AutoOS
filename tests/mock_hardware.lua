--[[
  AutoOS — Desktop Mock Hardware (README §5)

  Injects fake OpenComputers components so AutoOS logic can be validated off-game
  under a plain Lua interpreter. Provides mock gt_machine / computer / event
  proxies that match the surface the adapter and arbitrator use, plus call
  counters for verifying the architectural contracts:

    * adapter is the single poll point (one getSensorInformation per tick)
    * modules never touch hardware
    * arbitrator is the sole setWorkAllowed caller

  Optional fault schedule reproduces the README §5 emulator scenario, where a
  maintenance fault appears at a given tick and flips the machine off.
]]

local Mock = {}

-- Healthy lines must avoid every fault substring (incl. "problem"/"maintenance"
-- /"repair"/"structure") so substring matching does not false-positive.
local DEFAULT_HEALTHY = { "Running perfectly.", "Efficiency: 100%" }

-- opts:
--   healthy_sensor : string[]  sensor lines when healthy
--   fault_message  : string    sensor line injected when faulted
--   fault_at_tick  : number    poll index (1-based) at which the fault appears
--   clock_step     : number    seconds each uptime() call advances (default 0.01)
function Mock.new(opts)
  opts = opts or {}

  local healthy = opts.healthy_sensor or DEFAULT_HEALTHY
  local fault_message = opts.fault_message or "Machine needs a wrench!"

  local stats = {
    getSensorInformation = 0,
    isWorkAllowed = 0,
    isMachineActive = 0,
    getWorkProgress = 0,
    getWorkMaxProgress = 0,
    setWorkAllowed = 0,
    beep = 0,
    uptime = 0,
    pull = 0,
  }

  local state = {
    work_allowed = true,
    active = true,
    sensor = healthy,
    clock = 0,
    clock_step = opts.clock_step or 0.01,
    poll_index = 0, -- number of getSensorInformation calls so far
    fault_at_tick = opts.fault_at_tick, -- nil = never auto-fault
    last_beep = nil,
  }

  local machine = {
    getName = function() return "mb_01_platinum_line" end,
    getSensorInformation = function()
      stats.getSensorInformation = stats.getSensorInformation + 1
      state.poll_index = state.poll_index + 1
      -- Auto-inject the scheduled fault once the poll index reaches the target.
      if state.fault_at_tick and state.poll_index >= state.fault_at_tick then
        state.sensor = { "Running.", fault_message }
      end
      return state.sensor
    end,
    isWorkAllowed = function()
      stats.isWorkAllowed = stats.isWorkAllowed + 1
      return state.work_allowed
    end,
    isMachineActive = function()
      stats.isMachineActive = stats.isMachineActive + 1
      return state.active
    end,
    hasWork = function()
      return state.active
    end,
    getAverageElectricInput = function()
      return state.eu_input or 0
    end,
    getWorkProgress = function()
      stats.getWorkProgress = stats.getWorkProgress + 1
      return 0
    end,
    getWorkMaxProgress = function()
      stats.getWorkMaxProgress = stats.getWorkMaxProgress + 1
      return 100
    end,
    setWorkAllowed = function(v)
      stats.setWorkAllowed = stats.setWorkAllowed + 1
      state.work_allowed = v
      if v == false then
        state.active = false
      end
      return 1 -- packetPerTick, per gt-machine-api.md
    end,
  }

  local computer = {
    uptime = function()
      stats.uptime = stats.uptime + 1
      local now = state.clock
      state.clock = state.clock + state.clock_step
      return now
    end,
    beep = function(freq, duration)
      stats.beep = stats.beep + 1
      state.last_beep = { freq = freq, duration = duration }
    end,
  }

  local event = {
    -- No-op so desktop tests run instantly instead of sleeping.
    pull = function(_)
      stats.pull = stats.pull + 1
      return nil
    end,
  }

  return {
    machine = machine,
    computer = computer,
    event = event,
    state = state,
    stats = stats,

    -- Test helpers for manual scenario control.
    set_sensor = function(lines) state.sensor = lines end,
    set_fault = function(msg) state.sensor = { "Running.", msg or fault_message } end,
    set_healthy = function() state.sensor = healthy end,
    deps = function()
      return { machine = machine, computer = computer, event = event }
    end,
  }
end

return Mock
