--[[
  AutoOS — Dynamic ME → OC database descriptors (slot cache)

  Database slots are managed like a small cache instead of fixed scratch slots:

    * CACHE HIT  — a descriptor for this circuit/fluid is already in a slot and
                   the slot still holds the right thing → reuse it, no rewrite.
    * CACHE MISS — write to the first empty slot; if the database is full,
                   LRU-evict the broker-owned slot that has gone unused the
                   longest. Foreign slots (manual GUI / other scripts) are
                   never overwritten.

  Every write is verified by reading the slot back, so a stale slot can never
  silently feed the wrong circuit to the interface.

  Fluids: setFluidInterfaceConfiguration needs an ae2fc fluid drop in the slot.
  Drops only exist as ME items when a Fluid Discretizer is on the subnet.

  References: CommonNetworkAPI.store, database (get/set/clear), me_interface.lua
]]

local HW = require("hw")

local DescriptorCache = {}
DescriptorCache.__index = DescriptorCache

local DEFAULT_CIRCUIT_ITEM = "gregtech:gt.integrated_circuit"
local DEFAULT_SLOT_COUNT = 25
local FLUID_DROP_ITEM = "ae2fc:fluid_drop"

function DescriptorCache.new(deps)
  deps = deps or {}
  local self = setmetatable({}, DescriptorCache)
  self.config = deps.config or error("DescriptorCache.new: config required")
  self.component = deps.component or error("DescriptorCache.new: component required")
  self._entries = {}     -- cache_key -> { slot = n, last_used = t }
  self._slot_owner = {}  -- slot -> cache_key
  self._clock = 0        -- strictly monotonic logical clock (LRU ordering)
  return self
end

function DescriptorCache:_slot_count()
  return self.config.database_slot_count or DEFAULT_SLOT_COUNT
end

function DescriptorCache:_database_address()
  return self.config.database_address
end

function DescriptorCache:_circuit_item_name()
  return self.config.circuit_item_name or DEFAULT_CIRCUIT_ITEM
end

--- Strictly increasing logical clock for LRU ordering.
--- A logical counter (not wall time) guarantees tie-free ordering even when
--- many descriptors are touched within one game tick.
function DescriptorCache:_now()
  self._clock = self._clock + 1
  return self._clock
end

function DescriptorCache:_db()
  if self._db_proxy then return self._db_proxy end
  self._db_proxy = HW.proxy(self.component, self:_database_address(), "database")
  return self._db_proxy
end

--- Read a database slot back (nil when unavailable or empty).
function DescriptorCache:_db_get(slot)
  local db = self:_db()
  if not db or not db.get then return nil end
  local ok, entry = pcall(db.get, slot)
  if ok and type(entry) == "table" then return entry end
  return nil
end

function DescriptorCache:_db_clear(slot)
  local db = self:_db()
  if db and db.clear then pcall(db.clear, slot) end
end

--- Forget cached slot assignments (does not touch hardware).
function DescriptorCache:reset()
  self._entries = {}
  self._slot_owner = {}
end

--- Current cache state for diagnostics: { cache_key = { slot, last_used } }.
function DescriptorCache:debug_dump()
  local out = {}
  for key, e in pairs(self._entries) do
    out[key] = { slot = e.slot, last_used = e.last_used }
  end
  return out
end

--- Drop an owned slot from the cache maps.
function DescriptorCache:_forget_slot(slot)
  local key = self._slot_owner[slot]
  if key then self._entries[key] = nil end
  self._slot_owner[slot] = nil
end

--- Scan the database for a slot that already holds a matching descriptor.
--- Adopts descriptors written by a prior session or older broker code.
function DescriptorCache:_find_matching_slot(verify_fn)
  for slot = 1, self:_slot_count() do
    if verify_fn(self:_db_get(slot)) then
      return slot
    end
  end
  return nil
end

--- Find an empty database slot (not currently holding anything).
function DescriptorCache:_first_empty_slot()
  for slot = 1, self:_slot_count() do
    if self:_db_get(slot) == nil then
      return slot
    end
  end
  return nil
end

--- Pick the broker-owned slot unused for the longest (LRU). nil = none owned.
function DescriptorCache:_lru_owned_slot()
  local oldest_slot, oldest_time
  for slot, key in pairs(self._slot_owner) do
    local entry = self._entries[key]
    local t = entry and entry.last_used or 0
    if not oldest_time or t < oldest_time then
      oldest_time = t
      oldest_slot = slot
    end
  end
  return oldest_slot
end

--- Register a freshly written slot under cache_key (cleans any prior owner).
function DescriptorCache:_register(cache_key, slot)
  local prev_owner = self._slot_owner[slot]
  if prev_owner and prev_owner ~= cache_key then
    self._entries[prev_owner] = nil
  end
  self._entries[cache_key] = { slot = slot, last_used = self:_now() }
  self._slot_owner[slot] = cache_key
end

--- Resolve a database slot for a descriptor via cache hit / miss + LRU evict.
---@param cache_key string stable identity ("circuit:14", "fluid:Ethylene")
---@param write_fn fun(slot:integer):boolean,string|nil writes the descriptor
---@param verify_fn fun(entry:table|nil):boolean true when slot holds the descriptor
---@return boolean ok
---@return integer|string slot_or_err
function DescriptorCache:_resolve_slot(cache_key, write_fn, verify_fn)
  -- CACHE HIT: known slot still holds the right descriptor.
  local cached = self._entries[cache_key]
  if cached then
    if verify_fn(self:_db_get(cached.slot)) then
      cached.last_used = self:_now()
      return true, cached.slot
    end
    self:_forget_slot(cached.slot)  -- stale → fall through to miss
  end

  -- CACHE MISS: adopt an existing DB slot with the right descriptor, if any.
  local existing = self:_find_matching_slot(verify_fn)
  if existing then
    self:_register(cache_key, existing)
    return true, existing
  end

  -- No match — choose a slot to write.
  local slot = self:_first_empty_slot()
  local evicted = false
  if not slot then
    slot = self:_lru_owned_slot()
    if not slot then
      return false, string.format(
        "database full — all %d slots occupied by non-broker entries (clear some or raise database_slot_count)",
        self:_slot_count()
      )
    end
    self:_db_clear(slot)
    self:_forget_slot(slot)
    evicted = true
  end

  local ok_write, write_err = write_fn(slot)
  if not ok_write then
    return false, write_err or "descriptor write failed"
  end

  if not verify_fn(self:_db_get(slot)) then
    -- One clear + rewrite retry before giving up.
    self:_db_clear(slot)
    ok_write, write_err = write_fn(slot)
    if not ok_write or not verify_fn(self:_db_get(slot)) then
      return false, string.format(
        "database slot %d did not accept descriptor %q%s",
        slot, cache_key, evicted and " (after LRU eviction)" or ""
      )
    end
  end

  self:_register(cache_key, slot)
  return true, slot
end

-- ---------------------------------------------------------------- circuits

local function entry_is_circuit(entry, circuit_item, circuit_damage)
  if type(entry) ~= "table" then return false end
  local name = entry.name or ""
  if name ~= circuit_item and not name:find("integrated_circuit", 1, true) then
    return false
  end
  return entry.damage == circuit_damage
end

--- Resolve a database slot holding the requested programmed circuit.
---@param iface table lane me_interface proxy
---@param circuit_damage integer programmed circuit configuration (= damage)
---@return boolean ok
---@return integer|string slot_or_err
function DescriptorCache:ensure_circuit(iface, circuit_damage)
  local db_addr = self:_database_address()
  if not db_addr or db_addr == "" then
    return false, "database_address not configured"
  end

  local item_name = self:_circuit_item_name()
  local cache_key = "circuit:" .. tostring(circuit_damage)

  local function verify(entry)
    return entry_is_circuit(entry, item_name, circuit_damage)
  end

  local function write(slot)
    if iface and iface.store then
      local ok_store = iface.store({ name = item_name, damage = circuit_damage }, db_addr, slot, 1)
      if ok_store then return true end
    end
    -- Circuit not visible in subnet ME — synthesize the descriptor directly.
    local db = self:_db()
    if db and db.set then
      local ok_set, set_err = pcall(db.set, slot, item_name, circuit_damage)
      if ok_set and set_err ~= false then return true end
      return false, "database.set circuit failed: " .. tostring(set_err)
    end
    return false, string.format(
      "circuit %s not in subnet ME and database.set unavailable",
      tostring(circuit_damage)
    )
  end

  return self:_resolve_slot(cache_key, write, verify)
end

-- ------------------------------------------------------------------ fluids

local function lower(s)
  if type(s) ~= "string" then return nil end
  return s:lower()
end

--- Find the AE2FC drop item for a fluid label in the lane's ME network.
--- Drop items are labeled "drop of <Fluid>" and require a Fluid Discretizer.
---@return table|nil drop_stack
function DescriptorCache:_find_fluid_drop(iface, rules)
  if not iface or not iface.getItemsInNetwork then return nil end

  local want = lower(rules.fluid_label)
  local want_drop = want and ("drop of " .. want) or nil

  local stacks = iface.getItemsInNetwork({ name = FLUID_DROP_ITEM })
  if type(stacks) ~= "table" then return nil end

  -- Pass 1: exact "drop of <label>" match.
  if want_drop then
    for _, it in ipairs(stacks) do
      if lower(it.label) == want_drop then return it end
    end
  end
  -- Pass 2: label contains the fluid label.
  if want then
    for _, it in ipairs(stacks) do
      local l = lower(it.label)
      if l and l:find(want, 1, true) then return it end
    end
  end
  -- Pass 3: registry name in NBT tag.
  if rules.fluid_registry then
    local reg = lower(rules.fluid_registry)
    for _, it in ipairs(stacks) do
      local tag = lower(it.tag)
      if tag and tag:find(reg, 1, true) then return it end
    end
  end
  return nil
end

local function entry_is_fluid_drop(entry, want_label)
  if type(entry) ~= "table" then return false end
  local name = entry.name or ""
  if not name:find("fluid_drop", 1, true) then return false end
  if want_label and entry.label then
    return lower(entry.label):find(lower(want_label), 1, true) ~= nil
  end
  return true
end

--- Resolve a database slot holding the recipe's fluid drop descriptor.
---@param iface table lane me_interface proxy
---@param rules table recipe baseline (fluid_label / fluid_registry / fluid_filter)
---@return boolean ok
---@return integer|string slot_or_err
function DescriptorCache:ensure_fluid(iface, rules)
  local db_addr = self:_database_address()
  if not db_addr or db_addr == "" then
    return false, "database_address not configured"
  end
  if not iface or not iface.store then
    return false, "me_interface.store unavailable"
  end
  if not rules.fluid_label and not rules.fluid_registry and not rules.fluid_filter then
    return false, "recipe missing fluid_label or fluid_registry"
  end

  local hint = tostring(rules.fluid_label or rules.fluid_registry or "?")
  local cache_key = "fluid:" .. hint

  local filter = rules.fluid_filter
  if type(filter) ~= "table" then
    local drop = self:_find_fluid_drop(iface, rules)
    if not drop then
      local drops_visible = 0
      if iface.getItemsInNetwork then
        local all = iface.getItemsInNetwork({ name = FLUID_DROP_ITEM })
        drops_visible = type(all) == "table" and #all or 0
      end
      if drops_visible == 0 then
        return false, string.format(
          "no %q items in subnet ME — a Fluid Discretizer must be on the subnet for fluid stocking (looking for %q)",
          FLUID_DROP_ITEM, hint
        )
      end
      return false, string.format(
        "%d fluid drops in subnet ME but none match %q — check fluid_label against item labels (\"drop of ...\")",
        drops_visible, hint
      )
    end
    filter = { name = drop.name, damage = drop.damage or 0 }
    if drop.label then filter.label = drop.label end
  end

  local want_label = filter.label or rules.fluid_label

  local function verify(entry)
    return entry_is_fluid_drop(entry, want_label)
  end

  local function write(slot)
    local ok_store = iface.store(filter, db_addr, slot, 1)
    if ok_store then return true end
    return false, string.format("me.store failed for fluid drop %q", hint)
  end

  return self:_resolve_slot(cache_key, write, verify)
end

return DescriptorCache
