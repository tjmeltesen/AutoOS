--[[
  AutoOS — Resource Manager Module (Module 3, Priority 2)

  Pure logic. Reads the State Cache only — performs NO hardware calls.
  Implements raw resource management & projection (README §4 Phase 3):

    * Soft sleep — any tracked input missing or below its `min` floor emits a
      Priority 2 intent that pauses the machine (OFF, no maintenance beep).
      P2 suppresses Process Control's P3 refill for that tick; Maintenance
      (P1) still overrides everything.
    * Depletion alerts — when the adapter-computed time-to-depletion drops
      below `warn_ttd` while stock is draining, `self.last_alert` is set for
      exactly one tick (edge-triggered; the kernel logs/beeps on it).

  This module also owns the pure projection math the adapter uses to populate
  cache.history / cache.velocity / cache.ttd: ring-buffer append, consumption
  velocity (ΔR over the buffer window), and TTD. Exported as module-level
  functions so they are unit-testable without any hardware.

  References:
    references/phase3-implementation.md   (contracts, intent shape, math)
    references/me-network-api.md           (stock sampling source)
    README.md §3, §4                       (Priority 2, projection)
]]

local ResourceManager = {}
ResourceManager.__index = ResourceManager

-- Ring buffer length: 60 samples ≈ 30s of history at the 0.5s tick interval.
ResourceManager.HISTORY_CAP = 60

-- Minimum observation window for a velocity estimate (avoid div-by-near-zero).
local MIN_WINDOW = 1.0

--------------------------------------------------------------------------------
-- Pure projection math (no self, no hardware — shared with the adapter).
--------------------------------------------------------------------------------

-- Append one { t, count } sample, evicting the oldest beyond `cap`.
function ResourceManager.append_sample(ring, t, count, cap)
  cap = cap or ResourceManager.HISTORY_CAP
  ring[#ring + 1] = { t = t, count = count }
  while #ring > cap do
    table.remove(ring, 1)
  end
  return ring
end

-- Consumption velocity ΔR in units/second over the whole buffer window
-- (oldest vs newest sample — smooths single-tick ME jitter). Negative while
-- draining. nil when fewer than 2 samples or the window is under 1s.
function ResourceManager.compute_velocity(ring)
  if type(ring) ~= "table" or #ring < 2 then return nil end
  local oldest, newest = ring[1], ring[#ring]
  local dt = (newest.t or 0) - (oldest.t or 0)
  if dt < MIN_WINDOW then return nil end
  return (newest.count - oldest.count) / dt
end

-- Time-to-depletion in seconds. math.huge when stable/rising (never NaN);
-- nil when velocity is unknown.
function ResourceManager.compute_ttd(count, velocity)
  if velocity == nil or count == nil then return nil end
  if velocity >= 0 then return math.huge end
  return count / -velocity
end

--------------------------------------------------------------------------------
-- Module instance
--------------------------------------------------------------------------------

-- config = {
--   inputs = {                       -- tracked raw inputs (at least one)
--     { label = "...",               -- ME stock label (cache.stock key)
--       kind = "item"|"fluid",       -- adapter poll type (default "item")
--       min = <number>,              -- soft-sleep floor (items/mB)
--       warn_ttd = <seconds>,        -- depletion alert threshold (default 1800)
--       craft_label = "...",         -- optional getCraftables label override
--     }, ...
--   },
--   soft_sleep = true,               -- false = alert-only, never pause (default true)
--   alert_beep = true,               -- kernel beeps on depletion alert (default true)
-- }
function ResourceManager.new(config)
  assert(type(config) == "table", "ResourceManager.new: config table is required")
  assert(type(config.inputs) == "table" and #config.inputs > 0,
    "ResourceManager.new: config.inputs must list at least one input")
  for i, input in ipairs(config.inputs) do
    assert(input.label, ("ResourceManager.new: inputs[%d].label is required"):format(i))
    assert(type(input.min) == "number",
      ("ResourceManager.new: inputs[%d].min must be a number"):format(i))
  end

  local self = setmetatable({}, ResourceManager)
  self.inputs = {}
  for i, input in ipairs(config.inputs) do
    self.inputs[i] = {
      label = input.label,
      kind = input.kind or "item",
      min = input.min,
      warn_ttd = input.warn_ttd or 1800,
      craft_label = input.craft_label,
    }
  end
  self.soft_sleep = config.soft_sleep ~= false
  self.alert_beep = config.alert_beep ~= false

  -- Edge-trigger state: label -> true while its TTD warning condition holds.
  self._warned = {}
  -- Set for exactly one tick when a TTD warning first crosses its threshold.
  self.last_alert = nil

  self.evaluate = function(cache)
    return self:_evaluate(cache)
  end

  return self
end

-- Returns nil or ONE Priority 2 soft_sleep intent (never an array).
function ResourceManager:_evaluate(cache)
  self.last_alert = nil
  if type(cache) ~= "table" then return nil end

  local stock_tbl = type(cache.stock) == "table" and cache.stock or nil
  local velocity_tbl = type(cache.velocity) == "table" and cache.velocity or nil
  local ttd_tbl = type(cache.ttd) == "table" and cache.ttd or nil

  local sleep_intent = nil

  for _, input in ipairs(self.inputs) do
    local label = input.label
    local stock = stock_tbl and stock_tbl[label] or nil
    local velocity = velocity_tbl and velocity_tbl[label] or nil
    local ttd = ttd_tbl and ttd_tbl[label] or nil

    -- Depletion early-warning: edge-triggered so the kernel logs/beeps once
    -- per threshold crossing, not every tick.
    local warning = ttd ~= nil and velocity ~= nil
      and velocity < 0 and ttd < input.warn_ttd
    if warning then
      if not self._warned[label] then
        self._warned[label] = true
        self.last_alert = {
          label = label,
          ttd = ttd,
          velocity = velocity,
          warn_ttd = input.warn_ttd,
        }
      end
    else
      self._warned[label] = nil
    end

    -- Soft sleep on the first starved input. During GT power loss the machine
    -- is already self-paused — emitting OFF then would just be noise.
    if self.soft_sleep and sleep_intent == nil and not cache.power_loss
        and (stock == nil or stock < input.min) then
      sleep_intent = {
        priority = 2,
        module = "resource_manager",
        action = "soft_sleep",
        state = false,
        label = label,
        stock = stock,
        min = input.min,
        ttd = ttd,
        reason = string.format("input %s %s < min %d; soft sleep",
          label, stock ~= nil and tostring(stock) or "missing", input.min),
      }
    end
  end

  return sleep_intent
end

return ResourceManager
