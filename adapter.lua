--[[
  AutoOS — Hardware / Adapter Layer

  The ONLY layer permitted to read from hardware. Polls the injected
  gt_machine proxy exactly once per tick and writes atomic snapshots into a
  reused State Cache table. Logic modules never touch hardware; they read the
  cache produced here.

  Phase 2 adds optional ME-network inventory polling. When an `me` proxy and a
  target list are wired in, the adapter runs one filtered query per tracked
  product per tick and writes counts into a reused cache.stock table. Filtered
  queries (and a single getFluidsInNetwork scan) keep us within the per-tick
  budget and avoid allItems() (performance-pitfalls.md).

  References:
    references/autoos-api-mapping.md       (Hardware/Adapter Layer, Phase 2)
    references/gt-machine-api.md            (poll method set)
    references/me-network-api.md            (getItemsInNetwork filter, fluids)
    references/performance-pitfalls.md      (single poll point, table reuse, filters)
]]

local Adapter = {}
Adapter.__index = Adapter

-- machine  : gt_machine proxy (real component or mock)
-- computer : computer library (real or mock) — used for the tick timestamp
-- me       : ME network proxy (me_interface / me_controller) — optional
-- targets  : list of { label, kind = "item"|"fluid" } products to track — optional
function Adapter.new(machine, computer, me, targets)
  assert(machine, "Adapter.new: a gt_machine proxy is required")
  local self = setmetatable({}, Adapter)
  self.machine = machine
  self.computer = computer
  self.me = me
  self.targets = targets or {}
  return self
end

-- Resolve the current count of a single item target via a filtered query.
-- getItemsInNetwork({label=...}) returns only matching stacks (no full scan).
local function poll_item(me, label)
  local matches = me.getItemsInNetwork({ label = label })
  if type(matches) == "table" and matches[1] then
    return matches[1].size or 0
  end
  return 0
end

-- Resolve the current amount of a single fluid target. getFluidsInNetwork()
-- takes no filter, so it is scanned once per tick and reused across all fluid
-- targets by the caller.
local function find_fluid(fluids, label)
  if type(fluids) ~= "table" then return 0 end
  for _, stack in ipairs(fluids) do
    if stack.label == label then
      return stack.amount or 0
    end
  end
  return 0
end

-- Populate cache.stock for every configured target, reusing the existing table
-- (clear keys instead of allocating a new one — performance-pitfalls.md §Memory).
function Adapter:poll_inventory(cache)
  if not self.me or #self.targets == 0 then
    cache.stock = nil
    return
  end

  local stock = cache.stock
  if type(stock) ~= "table" then
    stock = {}
    cache.stock = stock
  else
    for k in pairs(stock) do stock[k] = nil end
  end

  -- Scan fluids at most once per tick, only if a fluid target exists.
  local fluids = nil
  for _, target in ipairs(self.targets) do
    if target.kind == "fluid" then
      if fluids == nil then
        fluids = self.me.getFluidsInNetwork and self.me.getFluidsInNetwork() or {}
      end
      stock[target.label] = find_fluid(fluids, target.label)
    else
      stock[target.label] = poll_item(self.me, target.label)
    end
  end

  self:poll_craftables(cache)
end

-- For each item target, check whether an ME autocraft recipe exists.
-- Modules read cache.craftable[label]; they never call getCraftables directly.
function Adapter:poll_craftables(cache)
  if not self.me or not self.me.getCraftables then
    cache.craftable = nil
    return
  end

  local craftable = cache.craftable
  if type(craftable) ~= "table" then
    craftable = {}
    cache.craftable = craftable
  else
    for k in pairs(craftable) do craftable[k] = nil end
  end

  local craft_labels = cache.craft_labels
  if type(craft_labels) ~= "table" then
    craft_labels = {}
    cache.craft_labels = craft_labels
  else
    for k in pairs(craft_labels) do craft_labels[k] = nil end
  end

  for _, target in ipairs(self.targets) do
    local key = target.label
    local craft_label = target.craft_label or target.label
    local resolved = craft_label
    local crafts = self.me.getCraftables({ label = craft_label })
    craftable[key] = type(crafts) == "table" and #crafts > 0
    -- GTNH fluid discretizer: also try "drop of <name>" when the primary label misses.
    if not craftable[key] and target.kind == "fluid" then
      local alt = "drop of " .. craft_label
      crafts = self.me.getCraftables({ label = alt })
      if type(crafts) == "table" and #crafts > 0 then
        craftable[key] = true
        resolved = alt
      end
    end
    if craftable[key] then
      craft_labels[key] = resolved
    end
  end
end

-- Poll all readings into the supplied cache table in one batch.
-- The same cache table is reused every tick to avoid per-tick allocation
-- (performance-pitfalls.md §Memory).
function Adapter:poll(cache)
  local m = self.machine

  cache.sensor = m.getSensorInformation()
  cache.work_allowed = m.isWorkAllowed()
  cache.active = m.isMachineActive()
  cache.has_work = m.hasWork and m.hasWork() or nil
  cache.progress = m.getWorkProgress and m.getWorkProgress() or nil
  cache.max_progress = m.getWorkMaxProgress and m.getWorkMaxProgress() or nil
  -- EU input average helps spot power loss (informational; not a shutdown trigger).
  cache.eu_input = m.getAverageElectricInput and m.getAverageElectricInput() or nil
  cache.time = self.computer and self.computer.uptime() or nil

  self:poll_inventory(cache)

  return cache
end

return Adapter
