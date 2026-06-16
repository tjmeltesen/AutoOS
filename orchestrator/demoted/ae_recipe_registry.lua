--[[
  AutoOS — AE recipe registry (living matched-recipe table)

  One row per known recipe, keyed by recipe_key, with a UNIQUE recipe_uid that
  disambiguates recipes sharing the same circuit_damage. by_uid gives O(1)
  lookup from a craft-token damage value back to a recipe.

    entries[recipe_key] = {
      recipe_key, recipe_uid, display_name, fluid_label, fluid_requirement,
      circuit_damage, craftable, source, last_scan, last_matched, match_count,
    }
    by_uid[recipe_uid] = recipe_key

  Persistence (recipe_uid stability across reboots) lives in registry_store.lua.

  References: plan phase_3_orchestrator "Dynamic AE recipe registry"
]]

local RegistryStore = require("demoted.registry_store")

local Registry = {}
Registry.__index = Registry

function Registry.new(deps)
  deps = deps or {}
  local cfg = deps.config or error("Registry.new: config required")
  local o = cfg.orchestrator or {}
  local self = setmetatable({}, Registry)
  self.config = cfg
  self.uid_bits = o.uid_bits or 16
  self.uid_min = o.uid_min or 1
  self.uid_max = (2 ^ self.uid_bits) - 1
  self.entries = {}
  self.by_uid = {}
  return self
end

-- UID allocation --------------------------------------------------------------

--- Lowest free uid >= uid_min (and the explicit one if free). nil,err on exhaustion.
---@param explicit integer|nil
---@return integer|nil uid, string|nil err
function Registry:allocate_uid(explicit)
  if explicit ~= nil then
    if type(explicit) ~= "number" or explicit < 1 or explicit > self.uid_max then
      return nil, "recipe_uid out of range (1.." .. self.uid_max .. ")"
    end
    if self.by_uid[explicit] then
      return nil, "recipe_uid " .. explicit .. " already used by " .. self.by_uid[explicit]
    end
    return explicit
  end
  for uid = self.uid_min, self.uid_max do
    if not self.by_uid[uid] then return uid end
  end
  return nil, "no free recipe_uid (uid space exhausted)"
end

-- Seeding / merging -----------------------------------------------------------

--- Insert or merge one recipe row. Allocates a uid when none is known.
---@param recipe_key string
---@param rule table baseline fields
---@param source string|nil
---@return boolean ok, string|nil err
function Registry:add(recipe_key, rule, source)
  if type(recipe_key) ~= "string" or recipe_key == "" then
    return false, "recipe_key required"
  end
  local existing = self.entries[recipe_key]
  local uid = existing and existing.recipe_uid or nil
  if uid == nil then
    local allocated, err = self:allocate_uid(rule.recipe_uid)
    if not allocated then return false, err end
    uid = allocated
  elseif rule.recipe_uid ~= nil and rule.recipe_uid ~= uid then
    -- Config asked for a new uid: only honor it if free.
    local allocated, err = self:allocate_uid(rule.recipe_uid)
    if not allocated then return false, err end
    self.by_uid[uid] = nil
    uid = allocated
  end

  local row = existing or { match_count = 0, last_scan = 0, last_matched = 0 }
  row.recipe_key = recipe_key
  row.recipe_uid = uid
  row.display_name = rule.display_name or row.display_name or recipe_key
  row.fluid_label = rule.fluid_label or row.fluid_label
  row.fluid_requirement = rule.fluid_requirement or row.fluid_requirement
  row.circuit_damage = rule.circuit_damage or row.circuit_damage
  if rule.craftable ~= nil then row.craftable = rule.craftable end
  row.source = source or row.source or "config"
  row.last_scan = rule.last_scan or row.last_scan or 0

  self.entries[recipe_key] = row
  self.by_uid[uid] = recipe_key
  return true, nil
end

--- Seed all rows from config.recipe_baselines. Returns ok, err on first failure.
function Registry:seed_from_config()
  local baselines = self.config.recipe_baselines or {}
  for key, rule in pairs(baselines) do
    local ok, err = self:add(key, rule, "config")
    if not ok then return false, "seed " .. key .. ": " .. tostring(err) end
  end
  return true
end

--- Re-merge config baselines (config wins on requirement / circuit). Never deletes.
function Registry:reload_baselines()
  return self:seed_from_config()
end

-- Validation ------------------------------------------------------------------

--- Confirm every row has a unique, in-range uid and a by_uid back-reference.
---@return boolean ok, string|nil err
function Registry:validate()
  local seen = {}
  for key, row in pairs(self.entries) do
    local uid = row.recipe_uid
    if type(uid) ~= "number" or uid < 1 or uid > self.uid_max then
      return false, key .. " has out-of-range recipe_uid"
    end
    if seen[uid] then
      return false, "duplicate recipe_uid " .. uid .. " (" .. seen[uid] .. " / " .. key .. ")"
    end
    seen[uid] = key
    if self.by_uid[uid] ~= key then
      return false, "by_uid index out of sync for uid " .. uid
    end
  end
  return true
end

-- Lookups ---------------------------------------------------------------------

function Registry:get(recipe_key)
  return self.entries[recipe_key]
end

--- Authoritative: resolve a craft-token uid to its recipe row.
function Registry:resolve_uid(uid)
  local key = self.by_uid[uid]
  if key then return self.entries[key] end
  return nil
end

--- Fallback: rows matching a fluid_label (optionally narrowed by circuit_damage).
---@return table[] rows
function Registry:resolve_delivery(circuit_damage, fluid_label)
  local matches = {}
  for _, row in pairs(self.entries) do
    local fluid_ok = fluid_label == nil or row.fluid_label == fluid_label
    local circuit_ok = circuit_damage == nil or row.circuit_damage == circuit_damage
    if fluid_ok and circuit_ok then
      matches[#matches + 1] = row
    end
  end
  return matches
end

--- Resolve a human / ME label to a row (display_name or fluid_label).
function Registry:lookup_label(label)
  for _, row in pairs(self.entries) do
    if row.display_name == label or row.fluid_label == label or row.recipe_key == label then
      return row
    end
  end
  return nil
end

-- Learning / maintenance ------------------------------------------------------

function Registry:confirm_uid(uid, now)
  local row = self:resolve_uid(uid)
  if not row then return false end
  row.last_matched = now or 0
  row.match_count = (row.match_count or 0) + 1
  row.source = "delivery_confirmed"
  return true
end

function Registry:mark_craftable(recipe_key, craftable, now)
  local row = self.entries[recipe_key]
  if not row then return false end
  row.craftable = craftable and true or false
  row.last_scan = now or row.last_scan
  return true
end

-- Persistence (delegated) -----------------------------------------------------

function Registry:save(path)
  return RegistryStore.save(path or (self.config.orchestrator or {}).registry_path, self.entries)
end

--- Load persisted rows, preserving uids. Config seed should run AFTER load so
--- explicit config uids reconcile against what was saved.
function Registry:load(path)
  local rows = RegistryStore.load(path or (self.config.orchestrator or {}).registry_path)
  if not rows then return false end
  for key, row in pairs(rows) do
    if type(row) == "table" and type(row.recipe_uid) == "number" then
      self.entries[key] = row
      self.by_uid[row.recipe_uid] = key
    end
  end
  return true
end

return Registry
