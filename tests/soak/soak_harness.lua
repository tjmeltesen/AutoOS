--[[
  AutoOS — Soak Test Harness
  Reusable tick-loop driver for long-duration simulations.
  Injects faults on a schedule, collects stats, checks invariants.

  Usage:
    local harness = SoakHarness.new({ machines = 4, cycles = 10000, fault_rate = 0.1 })
    harness:run()
    harness:report()
]]

local SoakHarness = {}
SoakHarness.__index = SoakHarness

function SoakHarness.new(opts)
  opts = opts or {}
  return setmetatable({
    machines = opts.machines or 4,
    cycles = opts.cycles or 1000,
    fault_rate = opts.fault_rate or 0.0,
    -- Stats
    stats = {
      cycles = 0,
      dispatched = 0,
      completed = 0,
      failed = 0,
      retried = 0,
      peak_queue = 0,
      peak_circuits = 0,
      stuck_lanes = 0,
      invariants_broken = 0,
    },
    -- Configurable callbacks
    on_tick = opts.on_tick,
    on_fault = opts.on_fault,
  }, SoakHarness)
end

function SoakHarness:should_fault()
  return math.random() < self.fault_rate
end

function SoakHarness:record(name, value)
  if value then
    self.stats[name] = self.stats[name] + value
  else
    self.stats[name] = self.stats[name] + 1
  end
end

function SoakHarness:update_peak(name, current)
  if current > self.stats[name] then
    self.stats[name] = current
  end
end

function SoakHarness:check_invariant(name, ok, detail)
  if not ok then
    self.stats.invariants_broken = self.stats.invariants_broken + 1
    if self.on_fault then
      self.on_fault("invariant", name, detail)
    end
  end
end

function SoakHarness:report()
  local s = self.stats
  local lines = {
    string.format("=== Soak Report (%d cycles) ===", s.cycles),
    string.format("  Dispatched:  %d", s.dispatched),
    string.format("  Completed:   %d", s.completed),
    string.format("  Failed:      %d", s.failed),
    string.format("  Retried:     %d", s.retried),
    string.format("  Peak queue:  %d", s.peak_queue),
    string.format("  Peak circuits: %d", s.peak_circuits),
    string.format("  Stuck lanes: %d", s.stuck_lanes),
    string.format("  Invariants broken: %d", s.invariants_broken),
  }
  return table.concat(lines, "\n")
end

function SoakHarness:save_report(filepath)
  local f = io.open(filepath, "w")
  if f then
    f:write(self:report())
    f:write("\n")
    f:close()
  end
end

return SoakHarness
