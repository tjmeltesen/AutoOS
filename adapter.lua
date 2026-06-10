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

-- Pure projection math only (ring append / velocity / TTD) — no logic coupling.
local ResourceMath = require("modules.resource_manager")

local Adapter = {}
Adapter.__index = Adapter

-- Strip Minecraft § color codes before substring matching sensor text.
local function strip_format(s)
  return (s:gsub("\194\167.", ""))
end

-- GT power-fail messages (distinct from maintenance — machine self-pauses).
local POWER_LOSS_PATTERNS = {
  "shut down due to power loss",
  "shut down due to power",
  "power loss",
  "insufficient energy",
  "not enough energy",
}

local function detect_power_loss(lines)
  if type(lines) ~= "table" then return false end
  for _, raw in ipairs(lines) do
    local lower = strip_format(raw):lower()
    for _, pat in ipairs(POWER_LOSS_PATTERNS) do
      if lower:find(pat, 1, true) then
        return true
      end
    end
  end
  return false
end

-- Match "<stored> EU / <capacity> EU" and return the stored amount.
-- GT may format numbers with thousands separators ("16,896 EU").
local function parse_eu_pair(s)
  local stored = s:match("([%d,]+)%s*EU%s*/%s*[%d,]+%s*EU")
  if not stored then return nil end
  return tonumber((stored:gsub(",", "")))
end

-- GT splits the scanner readout across sensor lines:
--   [Sensor 4] Stored Energy:
--   [Sensor 5] 16896 EU / 16896 EU
-- (validated in-game). Also handles both on one line. Returns nil when the
-- sensor carries no stored-energy readout at all.
local function parse_stored_eu_from_sensor(lines)
  if type(lines) ~= "table" then return nil end
  for i, raw in ipairs(lines) do
    local clean = strip_format(raw)
    if clean:lower():find("stored energy", 1, true) then
      local n = parse_eu_pair(clean)
      if n then return n end
      local nxt = lines[i + 1]
      if nxt then
        n = parse_eu_pair(strip_format(nxt))
        if n then return n end
      end
    end
  end
  return nil
end

-- Current EU/t usage from sensor text, for DISPLAY only (never power gating).
-- getAverageElectricInput() reads 0 on some controllers while a recipe runs;
-- the scanner readout is the reliable source. Same two-line split as stored
-- energy: a "Currently uses:" header line, value on the same or next line.
-- "Max Energy Income" is the hatch ceiling, not usage — deliberately ignored.
local EU_USAGE_HEADERS = {
  "currently uses",
  "current energy usage",
  "probably uses",
}

local function parse_eu_rate(s)
  local n = s:match("([%d,]+)%s*EU/t")
  if not n then return nil end
  return tonumber((n:gsub(",", "")))
end

local function parse_eu_usage_from_sensor(lines)
  if type(lines) ~= "table" then return nil end
  for i, raw in ipairs(lines) do
    local clean = strip_format(raw)
    local lower = clean:lower()
    for _, header in ipairs(EU_USAGE_HEADERS) do
      if lower:find(header, 1, true) then
        local n = parse_eu_rate(clean)
        if n then return n end
        local nxt = lines[i + 1]
        if nxt then
          n = parse_eu_rate(strip_format(nxt))
          if n then return n end
        end
      end
    end
  end
  return nil
end

-- machine  : gt_machine proxy (real component or mock)
-- computer : computer library (real or mock) — used for the tick timestamp
-- me       : ME network proxy (me_interface / me_controller) — optional
-- targets  : list of { label, kind = "item"|"fluid" } products to track — optional
-- history_labels : labels (subset of targets) to keep stock history rings for,
--                  feeding cache.velocity / cache.ttd (Phase 3) — optional
function Adapter.new(machine, computer, me, targets, history_labels)
  assert(machine, "Adapter.new: a gt_machine proxy is required")
  local self = setmetatable({}, Adapter)
  self.machine = machine
  self.computer = computer
  self.me = me
  self.targets = targets or {}
  self.history_labels = history_labels or {}
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

-- Append the current tick's stock samples to per-label history rings and
-- derive cache.velocity / cache.ttd (Phase 3 projection inputs). The rings and
-- the velocity/ttd maps are reused across ticks — no per-tick table churn
-- beyond the one sample entry (performance-pitfalls.md §Memory).
function Adapter:append_history(cache)
  if #self.history_labels == 0 then return end

  local history = cache.history
  if type(history) ~= "table" then
    history = {}
    cache.history = history
  end
  local velocity = cache.velocity
  if type(velocity) ~= "table" then
    velocity = {}
    cache.velocity = velocity
  end
  local ttd = cache.ttd
  if type(ttd) ~= "table" then
    ttd = {}
    cache.ttd = ttd
  end

  local t = cache.time
  for _, label in ipairs(self.history_labels) do
    local count = cache.stock and cache.stock[label]
    -- Skip when the reading is missing: a nil sample would poison velocity.
    if t ~= nil and count ~= nil then
      local ring = history[label]
      if type(ring) ~= "table" then
        ring = {}
        history[label] = ring
      end
      ResourceMath.append_sample(ring, t, count)
      local v = ResourceMath.compute_velocity(ring)
      velocity[label] = v
      ttd[label] = ResourceMath.compute_ttd(count, v)
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
  -- Explicit if/else: `m.hasWork and m.hasWork() or nil` would collapse a real
  -- false reading into nil (Lua and/or trap), hiding "machine has no work".
  if m.hasWork then
    cache.has_work = m.hasWork()
  else
    cache.has_work = nil
  end
  cache.progress = m.getWorkProgress and m.getWorkProgress() or nil
  cache.max_progress = m.getWorkMaxProgress and m.getWorkMaxProgress() or nil
  cache.eu_input = m.getAverageElectricInput and m.getAverageElectricInput() or nil
  -- Sensor text is the source of truth for stored EU: on this controller
  -- getStoredEU() returns 0 while the scanner shows a full buffer (validated
  -- in-game). Component value is only a fallback when the sensor has no readout.
  local sensed_stored = parse_stored_eu_from_sensor(cache.sensor)
  if sensed_stored ~= nil then
    cache.stored_eu = sensed_stored
    cache.stored_eu_source = "sensor"
  else
    cache.stored_eu = m.getStoredEU and m.getStoredEU() or nil
    cache.stored_eu_source = cache.stored_eu ~= nil and "component" or nil
  end

  cache.power_loss = detect_power_loss(cache.sensor)
  -- Drained-buffer power-fail detection: GT machines keep their internal buffer
  -- charged from the network even while idle/disabled (validated in-game:
  -- disabled electrolyzer reads 16896/16896 EU). The GUI's "Shut down due to
  -- power loss" text does NOT appear in getSensorInformation(), so a
  -- sensor-confirmed empty buffer with zero input is the power-fail signal.
  -- Only trusted when the value came from sensor text — getStoredEU() lies.
  if not cache.power_loss and cache.stored_eu_source == "sensor"
      and (cache.stored_eu or 0) <= 0 and (cache.eu_input or 0) <= 0 then
    cache.power_loss = true
  end
  cache.power_available = not cache.power_loss
  -- Display-only EU/t usage from sensor text (component eu_input reads 0 on
  -- some controllers while running). Never feeds power_loss gating.
  cache.eu_input_sensor = parse_eu_usage_from_sensor(cache.sensor)
  cache.time = self.computer and self.computer.uptime() or nil

  self:poll_inventory(cache)
  self:append_history(cache)

  return cache
end

return Adapter
