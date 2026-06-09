--[[
  AutoOS — Process Control Module (Module 1, Priority 3)

  Pure logic. Reads the State Cache only — performs NO hardware calls.
  Implements the dual-threshold hysteresis leveling loop (README §4 Phase 2):

    * stock < Threshold_low   -> enter STATE_ACTIVE (run the machine)
    * stock > Threshold_high  -> leave STATE_ACTIVE (stop the machine)
    * otherwise               -> HOLD the current state (deadband)

  The deadband between low/high prevents rapid on/off cycling ("flapping").
  Because the decision depends on the PREVIOUS state inside the band, this
  module is stateful: ProcessControl.new(config) returns an instance that
  remembers its `active` flag across ticks.

  The instance exposes a field-function `.evaluate(cache)` (not a method) so the
  kernel's existing `mod.evaluate(self.cache)` loop works unchanged, identical
  to the static modules/maintenance.lua surface.

  Inventory stock is read from cache.stock[label], populated once per tick by
  the adapter via filtered ME queries — modules never query the ME network.

  References:
    references/autoos-api-mapping.md      (Phase 2 hysteresis pattern)
    references/me-network-api.md           (stock counts come from the adapter)
    README.md §3, §4                       (Priority 3, leveling engine)
]]

local ProcessControl = {}
ProcessControl.__index = ProcessControl

-- config = { label = <string>, low = <number>, high = <number>, kind = "item"|"fluid" }
function ProcessControl.new(config)
  config = config or {}
  assert(config.label, "ProcessControl.new: config.label is required")
  assert(type(config.low) == "number", "ProcessControl.new: config.low must be a number")
  assert(type(config.high) == "number", "ProcessControl.new: config.high must be a number")
  assert(config.high > config.low,
    "ProcessControl.new: config.high must be greater than config.low (deadband)")

  local self = setmetatable({}, ProcessControl)
  self.label = config.label
  self.low = config.low
  self.high = config.high
  self.kind = config.kind or "item"

  -- Hysteresis state. Start inactive; the first sub-low reading turns it on.
  self.active = false

  -- Field-function wrapper so the kernel can call mod.evaluate(cache) uniformly
  -- across static (maintenance) and instance (process_control) modules.
  self.evaluate = function(cache)
    return self:_evaluate(cache)
  end

  return self
end

-- Look up the tracked product's current count from the cache.
-- Returns nil when the adapter has not populated stock for this label yet
-- (e.g. no ME proxy wired) so we can safely hold state.
function ProcessControl:_stock(cache)
  if type(cache) ~= "table" or type(cache.stock) ~= "table" then
    return nil
  end
  return cache.stock[self.label]
end

-- Apply the dual-threshold hysteresis transition for a given stock level.
-- Mutates self.active and returns it.
function ProcessControl:_apply(stock)
  if stock < self.low then
    self.active = true
  elseif stock > self.high then
    self.active = false
  end
  -- Inside the deadband [low, high]: hold the current state.
  return self.active
end

-- Evaluate the cache and emit a Priority 3 set_work_allowed intent.
-- Holds the current state when stock is unknown (no reading available).
function ProcessControl:_evaluate(cache)
  local stock = self:_stock(cache)
  if stock == nil then
    -- No inventory reading; hold whatever state we last decided on.
    return {
      priority = 3,
      module = "process_control",
      action = "set_work_allowed",
      state = self.active,
      stock = nil,
      reason = string.format("%s stock unknown; holding %s",
        self.label, self.active and "ACTIVE" or "IDLE"),
    }
  end

  local active = self:_apply(stock)
  local reason
  if active then
    reason = string.format("%s %d < high %d; running to refill",
      self.label, stock, self.high)
  else
    reason = string.format("%s %d >= high %d; stock satisfied",
      self.label, stock, self.high)
  end

  return {
    priority = 3,
    module = "process_control",
    action = "set_work_allowed",
    state = active,
    stock = stock,
    reason = reason,
  }
end

return ProcessControl
