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
    -- Phase 2 ME-network call counters (single-poll-point contract).
    getItemsInNetwork = 0,
    getFluidsInNetwork = 0,
    getCraftables = 0,
    craft_request = 0,
    me_calls = 0,
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
    -- Phase 2 inventory: label -> count (items) / label -> amount (fluids).
    stock = opts.stock or {},
    fluids = opts.fluids or {},
    -- Labels with ME autocraft recipes (getCraftables returns a match).
    craftables = opts.craftables or {},
    craft_jobs = {},
    last_craft = nil,
    craft_done = opts.craft_done ~= false, -- jobs finish immediately in mock
    -- Default powered so existing tests don't need per-case setup.
    eu_input = opts.eu_input ~= nil and opts.eu_input or 128,
    stored_eu = opts.stored_eu ~= nil and opts.stored_eu or 0,
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
    getStoredEU = function()
      return state.stored_eu or 0
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
      -- Mirror the GT machine: disabling work stops it; re-enabling lets it run.
      state.active = v and true or false
      return 1 -- packetPerTick, per gt-machine-api.md
    end,
  }
  if opts.no_getStoredEU then
    machine.getStoredEU = nil
  end

  -- Phase 2 mock ME network. Honors the {label=...} filter on items; fluids are
  -- returned in full (getFluidsInNetwork takes no filter per me-network-api.md).
  local me = {
    getItemsInNetwork = function(filter)
      stats.getItemsInNetwork = stats.getItemsInNetwork + 1
      stats.me_calls = stats.me_calls + 1
      local out = {}
      if type(filter) == "table" and filter.label then
        local size = state.stock[filter.label]
        if size ~= nil then
          out[1] = { label = filter.label, size = size, name = filter.label }
        end
      else
        for label, size in pairs(state.stock) do
          out[#out + 1] = { label = label, size = size, name = label }
        end
      end
      return out
    end,
    getFluidsInNetwork = function()
      stats.getFluidsInNetwork = stats.getFluidsInNetwork + 1
      stats.me_calls = stats.me_calls + 1
      local out = {}
      for label, amount in pairs(state.fluids) do
        out[#out + 1] = { label = label, amount = amount, name = label }
      end
      return out
    end,
    getCraftables = function(filter)
      stats.getCraftables = stats.getCraftables + 1
      stats.me_calls = stats.me_calls + 1
      if type(filter) == "table" and filter.label and state.craftables[filter.label] then
        return {{
          label = filter.label,
          request = function(amount, prioritize_power)
            stats.craft_request = stats.craft_request + 1
            state.last_craft = {
              label = filter.label,
              amount = amount,
              prioritize_power = prioritize_power,
            }
            local job = {
              isDone = function() return state.craft_done end,
              hasFailed = function() return false end,
              isCanceled = function() return false end,
              isComputing = function() return not state.craft_done end,
            }
            state.craft_jobs[filter.label] = job
            return job
          end,
        }}
      end
      return {}
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

  -- Mock GPU for the read-only status display. Records the last text written to
  -- each row so tests can assert that rendering happened, plus call counters.
  stats.gpu_set = 0
  stats.gpu_fill = 0
  local gpu = {
    bind = function(addr) state.gpu_bound = addr; return true end,
    getScreen = function() return state.gpu_bound end,
    maxResolution = function() return 80, 25 end,
    getResolution = function() return state.gpu_w or 60, state.gpu_h or 16 end,
    setResolution = function(w, h) state.gpu_w, state.gpu_h = w, h; return true end,
    getSize = function() return state.gpu_w or 60, state.gpu_h or 16 end,
    setForeground = function(c) state.gpu_fg = c; return c end,
    setBackground = function(c) state.gpu_bg = c; return c end,
    fill = function(_, _, _, _, _)
      stats.gpu_fill = stats.gpu_fill + 1
      return true
    end,
    set = function(x, y, value)
      stats.gpu_set = stats.gpu_set + 1
      state.gpu_rows[y] = value
      return true
    end,
  }
  state.gpu_rows = {}

  return {
    machine = machine,
    computer = computer,
    event = event,
    me = me,
    gpu = gpu,
    state = state,
    stats = stats,

    -- Test helpers for manual scenario control.
    set_sensor = function(lines) state.sensor = lines end,
    set_power = function(eu_in, stored_eu)
      state.eu_input = eu_in or 0
      state.stored_eu = stored_eu or 0
    end,
    set_fault = function(msg) state.sensor = { "Running.", msg or fault_message } end,
    set_healthy = function() state.sensor = healthy end,
    set_stock = function(label, n) state.stock[label] = n end,
    set_fluid = function(label, n) state.fluids[label] = n end,
    set_craftable = function(label, available)
      if available then state.craftables[label] = true else state.craftables[label] = nil end
    end,
    set_craft_pending = function(label)
      state.craft_done = false
      state.craft_jobs[label] = {
        isDone = function() return false end,
        hasFailed = function() return false end,
        isCanceled = function() return false end,
        isComputing = function() return true end,
      }
    end,
    advance_clock = function(seconds)
      state.clock = state.clock + (seconds or 0)
    end,
    deps = function()
      return { machine = machine, computer = computer, event = event, me = me }
    end,
  }
end

return Mock
