--[[
  Universal Craft Brokers — coordinator stock watcher (hysteresis only).

  Product-focused: emits craft needs when stock is below low band; holds ACTIVE
  through deadband until stock >= high.
]]

local RecipeRegistry = require("shared.recipe_registry")

local StockWatcher = {}
StockWatcher.__index = StockWatcher

function StockWatcher.new(targets, opts)
  opts = opts or {}
  local self = setmetatable({}, StockWatcher)
  self.targets = {}
  self.active = {}
  self.validate_registry = opts.validate_registry ~= false

  for _, t in ipairs(targets or {}) do
    assert(t.label, "target requires label")
    assert(type(t.low) == "number" and type(t.high) == "number", "target bands required")
    assert(t.high > t.low, "target high must exceed low")
    if self.validate_registry then
      assert(RecipeRegistry.known(t.label),
        "unknown recipe in registry: " .. tostring(t.label))
    end
    self.targets[#self.targets + 1] = t
    self.active[t.label] = false
  end

  return self
end

function StockWatcher:_stock(cache, label)
  if type(cache) ~= "table" or type(cache.stock) ~= "table" then
    return nil
  end
  return cache.stock[label]
end

function StockWatcher:evaluate(cache, in_flight)
  in_flight = in_flight or {}
  local needs = {}

  for _, t in ipairs(self.targets) do
    local stock = self:_stock(cache, t.label)
    if stock ~= nil then
      if stock < t.low then
        self.active[t.label] = true
      elseif stock >= t.high then
        self.active[t.label] = false
      end
    end

    if self.active[t.label] and stock ~= nil and stock < t.high then
      local amount = t.high - stock
      if t.max_craft then
        amount = math.min(amount, t.max_craft)
      end
      if amount > 0 and not in_flight[t.label] then
        needs[#needs + 1] = {
          label = t.label,
          kind = t.kind or "item",
          amount = amount,
          stock = stock,
        }
      end
    end
  end

  return needs
end

function StockWatcher:is_active(label)
  return self.active[label] == true
end

return StockWatcher
