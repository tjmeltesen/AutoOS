--[[
  AutoOS — Process Control Module (Module 1, Priority 3)

  Pure logic. Reads the State Cache only — performs NO hardware calls.
  Implements the dual-threshold hysteresis leveling loop (README §4 Phase 2):

    * stock < Threshold_low   -> enter STATE_ACTIVE (refill)
    * stock > Threshold_high  -> leave STATE_ACTIVE (satisfied)
    * otherwise               -> HOLD the current state (deadband)

  When ACTIVE, replenishment can use one or both paths (config.mode):

    * "machine" — drive gt_machine via set_work_allowed (physical processing)
    * "craft"   — request ME autocraft via request_craft (getCraftables recipes).
                  While refilling, also ensures work_allowed=true: the ME pattern
                  executes ON the bound machine, so a switched-off machine would
                  hang every dispatched job forever. Never turns the machine off.
    * "both"    — machine on + ME craft request each tick while refilling

  ME craft intents carry amount = high - stock (deficit to the upper band).
  Craftability is read from cache.craftable[label], populated by the adapter.
  The arbitrator commits crafts and throttles duplicate requests while a job
  is still computing (me-network-api.md AECraftingJob).

  References:
    references/autoos-api-mapping.md      (Phase 2 hysteresis + crafting API)
    references/me-network-api.md           (getCraftables, request, job status)
    README.md §3, §4                       (Priority 3, leveling engine)
]]

local ProcessControl = {}
ProcessControl.__index = ProcessControl

local VALID_MODES = { machine = true, craft = true, both = true }

-- config = {
--   label, low, high,
--   kind = "item"|"fluid",
--   mode = "machine"|"craft"|"both",   -- default "machine" (desktop tests)
--   prioritize_power = true,           -- passed to craftables[1].request()
--   max_craft = <number>,              -- optional cap per request (mB/items)
-- }
function ProcessControl.new(config)
  config = config or {}
  assert(config.label, "ProcessControl.new: config.label is required")
  assert(type(config.low) == "number", "ProcessControl.new: config.low must be a number")
  assert(type(config.high) == "number", "ProcessControl.new: config.high must be a number")
  assert(config.high > config.low,
    "ProcessControl.new: config.high must be greater than config.low (deadband)")

  local mode = config.mode or "machine"
  assert(VALID_MODES[mode],
    'ProcessControl.new: config.mode must be "machine", "craft", or "both"')

  local self = setmetatable({}, ProcessControl)
  self.label = config.label
  -- craft_label: label passed to getCraftables when it differs from stock label
  -- (e.g. stock tracked as fluid "Oxygen" but craft filter uses another spelling).
  self.craft_label = config.craft_label or config.label
  self.low = config.low
  self.high = config.high
  self.kind = config.kind or "item"
  self.mode = mode
  self.prioritize_power = config.prioritize_power ~= false
  self.max_craft = config.max_craft -- nil = no cap (full deficit to high)

  -- Hysteresis state. Start inactive; the first sub-low reading turns it on.
  self.active = false

  self.evaluate = function(cache)
    return self:_evaluate(cache)
  end

  return self
end

function ProcessControl:_stock(cache)
  if type(cache) ~= "table" or type(cache.stock) ~= "table" then
    return nil
  end
  return cache.stock[self.label]
end

function ProcessControl:_craftable(cache)
  if type(cache) ~= "table" or type(cache.craftable) ~= "table" then
    return false
  end
  -- Adapter keys craftability by the stock label (config.label).
  return cache.craftable[self.label] == true
end

-- GT power-fail self-pauses the machine (sensor text). Do not emit ON or craft
-- while that stands. eu_in=0 on an idle line is normal — not a power-fail signal.
function ProcessControl:_power_ok(cache)
  if type(cache) ~= "table" then return true end
  return not cache.power_loss
end

function ProcessControl:_apply(stock)
  if stock < self.low then
    self.active = true
  elseif stock >= self.high then
    -- >= (not >): hitting high exactly means the band is satisfied; > alone
    -- left the state stuck ACTIVE at stock == high (refilling forever).
    self.active = false
  end
  return self.active
end

function ProcessControl:_wants_machine()
  return self.mode == "machine" or self.mode == "both"
end

function ProcessControl:_wants_craft()
  -- Items and fluids (GTNH AE fluid patterns) both use getCraftables → request.
  return self.mode == "craft" or self.mode == "both"
end

-- Build zero, one, or two Priority 3 intents for the arbitrator.
function ProcessControl:_evaluate(cache)
  local stock = self:_stock(cache)
  local intents = {}

  if stock == nil then
    if self:_wants_machine() then
      intents[#intents + 1] = {
        priority = 3,
        module = "process_control",
        action = "set_work_allowed",
        state = self.active,
        stock = nil,
        reason = string.format("%s stock unknown; holding %s",
          self.label, self.active and "ACTIVE" or "IDLE"),
      }
    end
    return self:_return_intents(intents)
  end

  local active = self:_apply(stock)

  if self:_wants_machine() then
    local reason
    if active then
      reason = string.format("%s %d < high %d; running to refill",
        self.label, stock, self.high)
    else
      reason = string.format("%s %d >= high %d; stock satisfied",
        self.label, stock, self.high)
    end
    -- Turning OFF when satisfied is always safe. Turning ON requires power.
    if not active or self:_power_ok(cache) then
      intents[#intents + 1] = {
        priority = 3,
        module = "process_control",
        action = "set_work_allowed",
        state = active,
        stock = stock,
        reason = reason,
      }
    end
  elseif self.mode == "craft" and active and self:_power_ok(cache) then
    -- Craft mode: the ME pattern runs on the bound machine. Keep it enabled
    -- while refilling or dispatched jobs hang on a switched-off machine.
    -- ON only — craft mode never turns the machine off. Skip when power is dead.
    intents[#intents + 1] = {
      priority = 3,
      module = "process_control",
      action = "set_work_allowed",
      state = true,
      stock = stock,
      reason = string.format("%s refilling; machine enabled for ME craft", self.label),
    }
  end

  -- ME autocraft: request while ACTIVE and still below the high band.
  if self:_wants_craft() and active and stock < self.high and self:_craftable(cache)
      and self:_power_ok(cache) then
    local amount = self.high - stock
    if self.max_craft then
      amount = math.min(amount, self.max_craft)
    end
    if amount > 0 then
      intents[#intents + 1] = {
        priority = 3,
        module = "process_control",
        action = "request_craft",
        label = (cache.craft_labels and cache.craft_labels[self.label]) or self.craft_label,
        stock_label = self.label,
        amount = amount,
        stock = stock,
        prioritize_power = self.prioritize_power,
        reason = string.format("%s %d < high %d; ME craft %d",
          self.label, stock, self.high, amount),
      }
    end
  end

  return self:_return_intents(intents)
end

-- Return nil, a single intent table, or an array of intents for the kernel.
function ProcessControl:_return_intents(intents)
  if #intents == 0 then return nil end
  if #intents == 1 then return intents[1] end
  return intents
end

return ProcessControl
