--[[
  AutoOS — Hardware / Adapter Layer

  The ONLY layer permitted to read from hardware. Polls the injected
  gt_machine proxy exactly once per tick and writes atomic snapshots into a
  reused State Cache table. Logic modules never touch hardware; they read the
  cache produced here.

  References:
    references/autoos-api-mapping.md       (Hardware/Adapter Layer)
    references/gt-machine-api.md            (poll method set)
    references/performance-pitfalls.md      (single poll point, table reuse)
]]

local Adapter = {}
Adapter.__index = Adapter

-- machine  : gt_machine proxy (real component or mock)
-- computer : computer library (real or mock) — used for the tick timestamp
function Adapter.new(machine, computer)
  assert(machine, "Adapter.new: a gt_machine proxy is required")
  local self = setmetatable({}, Adapter)
  self.machine = machine
  self.computer = computer
  return self
end

-- Poll all Phase 1 readings into the supplied cache table in one batch.
-- The same cache table is reused every tick to avoid per-tick allocation
-- (performance-pitfalls.md §Memory).
function Adapter:poll(cache)
  local m = self.machine

  cache.sensor = m.getSensorInformation()
  cache.work_allowed = m.isWorkAllowed()
  cache.active = m.isMachineActive()
  cache.progress = m.getWorkProgress and m.getWorkProgress() or nil
  cache.max_progress = m.getWorkMaxProgress and m.getWorkMaxProgress() or nil
  cache.time = self.computer and self.computer.uptime() or nil

  return cache
end

return Adapter
