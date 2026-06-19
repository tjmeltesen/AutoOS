--[[
  AutoOS — Dynamic ME → OC database descriptors (slot cache)

  Database slots are managed like a small cache instead of fixed scratch slots:

    * CACHE HIT  — descriptor already in a slot and verified.
    * CACHE MISS — write to first empty slot, otherwise LRU-evict a broker-owned slot.

  Foreign slots (manual GUI / other scripts) are never overwritten.
]]

local HW = require("hw")

local DescriptorCache = {}
DescriptorCache.__index = DescriptorCache

local DEFAULT_CIRCUIT_ITEM = "gregtech:gt.integrated_circuit"
local DEFAULT_SLOT_COUNT = 25
local FLUID_DROP_ITEM = "ae2fc:fluid_drop"

local function lower(s)
  if type(s) ~= "string" then return nil end
  return s:lower()
end

function DescriptorCache.new(deps)
  deps = deps or {}
  local self = setmetatable({}, DescriptorCache)
  self.config = deps.config or error("DescriptorCache.new: config required")
  self.component = deps.component or error("DescriptorCache.new: component required")
  self._entries = {}     -- cache_key -> { slot = n, last_used = t }
  self._slot_owner = {}  -- slot -> cache_key
  self._slot_refs = {}   -- slot -> active interface config reference count
  self._clock = 0
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

function DescriptorCache:_now()
  self._clock = self._clock + 1
  return self._clock
end

function DescriptorCache:_db()
  if self._db_proxy then return self._db_proxy end
  self._db_proxy = HW.proxy(self.component, self:_database_address(), "database")
  return self._db_proxy
end

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

function DescriptorCache:reset()
  self._entries = {}
  self._slot_owner = {}
  self._slot_refs = {}
end

function DescriptorCache:debug_dump()
  local out = {}
  for key, e in pairs(self._entries) do
    out[key] = { slot = e.slot, last_used = e.last_used }
  end
  return out
end

function DescriptorCache:_forget_slot(slot)
  local key = self._slot_owner[slot]
  if key then self._entries[key] = nil end
  self._slot_owner[slot] = nil
  self._slot_refs[slot] = nil
end

function DescriptorCache:_first_empty_slot()
  for slot = 1, self:_slot_count() do
    if self:_db_get(slot) == nil then return slot end
  end
  return nil
end

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

function DescriptorCache:_register(cache_key, slot)
  local prev_owner = self._slot_owner[slot]
  if prev_owner and prev_owner ~= cache_key then
    self._entries[prev_owner] = nil
  end
  self._entries[cache_key] = { slot = slot, last_used = self:_now() }
  self._slot_owner[slot] = cache_key
  self._slot_refs[slot] = self._slot_refs[slot] or 0
end

function DescriptorCache:_reserve_slot(slot)
  if type(slot) ~= "number" then return end
  self._slot_refs[slot] = (self._slot_refs[slot] or 0) + 1
end

function DescriptorCache:_find_matching_slot(verify_fn)
  for slot = 1, self:_slot_count() do
    if verify_fn(self:_db_get(slot)) then return slot end
  end
  return nil
end

function DescriptorCache:_resolve_slot(cache_key, write_fn, verify_fn)
  local cached = self._entries[cache_key]
  if cached then
    if verify_fn(self:_db_get(cached.slot)) then
      cached.last_used = self:_now()
      self:_reserve_slot(cached.slot)
      return true, cached.slot
    end
    self:_forget_slot(cached.slot)
  end

  local existing = self:_find_matching_slot(verify_fn)
  if existing then
    self:_register(cache_key, existing)
    self:_reserve_slot(existing)
    return true, existing
  end

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
  if not ok_write then return false, write_err or "descriptor write failed" end

  if not verify_fn(self:_db_get(slot)) then
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
  self:_reserve_slot(slot)
  return true, slot
end

local function entry_is_item(entry, spec)
  if type(entry) ~= "table" then return false end
  if spec.name and entry.name ~= spec.name then return false end
  if spec.damage ~= nil and entry.damage ~= spec.damage then return false end
  if spec.label and entry.label then
    return lower(entry.label) == lower(spec.label)
  end
  return true
end

function DescriptorCache:ensure_item(iface, spec)
  spec = spec or {}
  local db_addr = self:_database_address()
  if not db_addr or db_addr == "" then
    return false, "database_address not configured"
  end
  if not spec.name then
    return false, "ensure_item requires spec.name"
  end

  local damage = spec.damage or 0
  local cache_key = spec.cache_key
    or string.format("item:%s:%s:%s",
      tostring(spec.name), tostring(damage), tostring(spec.label or ""))

  local filter = { name = spec.name, damage = damage }
  if spec.label then filter.label = spec.label end
  local count = spec.count or 1

  local function verify(entry)
    return entry_is_item(entry, { name = spec.name, damage = damage, label = spec.label })
  end

  local function write(slot)
    if iface and iface.store then
      local ok_store = iface.store(filter, db_addr, slot, count)
      if ok_store then return true end
    end
    local db = self:_db()
    if db and db.set and not spec.label then
      local ok_set, set_err = pcall(db.set, slot, spec.name, damage)
      if ok_set and set_err ~= false then return true end
      return false, "database.set item failed: " .. tostring(set_err)
    end
    return false, string.format("me.store failed for item %q", tostring(spec.name))
  end

  return self:_resolve_slot(cache_key, write, verify)
end

function DescriptorCache:ensure_circuit(iface, circuit_damage)
  return self:ensure_item(iface, {
    name = self:_circuit_item_name(),
    damage = circuit_damage,
    count = 1,
    cache_key = "circuit:" .. tostring(circuit_damage),
  })
end

function DescriptorCache:_find_fluid_drop(iface, rules)
  if not iface or not iface.getItemsInNetwork then return nil end
  local want = lower(rules.fluid_label)
  local want_drop = want and ("drop of " .. want) or nil
  local stacks = iface.getItemsInNetwork({ name = FLUID_DROP_ITEM })
  if type(stacks) ~= "table" then return nil end

  if want_drop then
    for _, it in ipairs(stacks) do
      if lower(it.label) == want_drop then return it end
    end
  end
  if want then
    for _, it in ipairs(stacks) do
      local l = lower(it.label)
      if l and l:find(want, 1, true) then return it end
    end
  end
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

function DescriptorCache:release_slots(slots)
  if type(slots) ~= "table" then return 0 end
  local released = 0
  local seen = {}
  for _, slot in ipairs(slots) do
    if type(slot) == "number" and slot >= 1 and not seen[slot] then
      seen[slot] = true
      if self._slot_owner[slot] ~= nil then
        local refs = (self._slot_refs[slot] or 1) - 1
        if refs > 0 then
          self._slot_refs[slot] = refs
        else
          self:_db_clear(slot)
          self:_forget_slot(slot)
        end
        released = released + 1
      end
    end
  end
  return released
end

return DescriptorCache
