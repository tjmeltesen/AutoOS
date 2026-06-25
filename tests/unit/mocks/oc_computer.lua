--[[
  AutoOS — OC computer API mock
  Models: computer.uptime(), computer.maxEnergy(), computer.energy(), computer.beep()

  Usage:
    local mock_computer = OCComputerMock.new({ uptime = 0 })
    local t = mock_computer.uptime()  -- 0
    mock_computer.tick(1.5)
    local t = mock_computer.uptime()  -- 1.5
]]

local OCComputerMock = {}

function OCComputerMock.new(opts)
  opts = opts or {}
  local self = {
    _uptime = opts.uptime or 0,
    _max_energy = opts.max_energy or 100000,
    _energy = opts.energy or 100000,
    _beeps = {},
    _call_counts = { uptime = 0, maxEnergy = 0, energy = 0, beep = 0 },
  }
  setmetatable(self, { __index = OCComputerMock })
  return self
end

--- computer.uptime() -> number (seconds)
function OCComputerMock.uptime(self)
  self._call_counts.uptime = self._call_counts.uptime + 1
  return self._uptime
end

--- computer.maxEnergy() -> number
function OCComputerMock.maxEnergy(self)
  self._call_counts.maxEnergy = self._call_counts.maxEnergy + 1
  return self._max_energy
end

--- computer.energy() -> number
function OCComputerMock.energy(self)
  self._call_counts.energy = self._call_counts.energy + 1
  return self._energy
end

--- computer.beep([frequency])
function OCComputerMock.beep(self, frequency)
  self._call_counts.beep = self._call_counts.beep + 1
  self._beeps[#self._beeps + 1] = frequency or 440
end

--- Advance time by n seconds
function OCComputerMock.tick(self, seconds)
  self._uptime = self._uptime + (seconds or 0.05)
end

function OCComputerMock.get_call_counts(self)
  return self._call_counts
end

function OCComputerMock.get_beeps(self)
  return self._beeps
end

return OCComputerMock
