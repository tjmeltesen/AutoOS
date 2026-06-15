--[[
  AutoOS — Broker recipe registry

  Seeds from config baselines, grows via AE pattern scan, persists uids.
]]

local RegistryStore = require("registry_store")

local BrokerRegistry = {}
BrokerRegistry.__index = BrokerRegistry

function BrokerRegistry.new(config)
  local self = setmetatable({}, BrokerRegistry)
  self.config = config or {}
  self.uid_bits = config.uid_bits or 16
  self.uid_min = config.uid_min or 256
  self.uid_max = (2 ^ self.uid_bits) - 1
  self.entries = {}
  self.by_uid = {}
  return self
end

function BrokerRegistry:allocate_uid(explicit)
  if explicit ~= nil then
    if type(explicit) ~= "number" or explicit < 1 or explicit > self.uid_max then
      return nil, "recipe_uid out of range"
    end
    if self.by_uid[explicit] then
      return nil, "recipe_uid " .. explicit .. " already used"
    end
    return explicit
  end
  for uid = self.uid_min, self.uid_max do
    if not self.by_uid[uid] then return uid end
  end
  return nil, "no free recipe_uid"
end

function BrokerRegistry:add(recipe_key, rule, source)
  if type(recipe_key) ~= "string" or recipe_key == "" then
    return false, "recipe_key required"
  end
  rule = rule or {}
  local existing = self.entries[recipe_key]
  local uid = existing and existing.recipe_uid or nil
  if uid == nil then
    local allocated, err = self:allocate_uid(rule.recipe_uid)
    if not allocated then return false, err end
    uid = allocated
  elseif rule.recipe_uid ~= nil and rule.recipe_uid ~= uid then
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
  row.default_dispatch_mB = rule.default_dispatch_mB or row.default_dispatch_mB
  if rule.craftable ~= nil then row.craftable = rule.craftable end
  row.source = source or row.source or "config"
  row.last_scan = rule.last_scan or row.last_scan or 0

  self.entries[recipe_key] = row
  self.by_uid[uid] = recipe_key
  return true, nil
end

function BrokerRegistry:seed_from_config()
  local baselines = self.config.constraints and self.config.constraints.recipe_baselines or {}
  for key, rule in pairs(baselines) do
    local ok, err = self:add(key, rule, "config")
    if not ok then return false, "seed " .. key .. ": " .. tostring(err) end
  end
  return true
end

function BrokerRegistry:resolve_uid(uid)
  local key = self.by_uid[uid]
  if key then return self.entries[key] end
  return nil
end

function BrokerRegistry:resolve_delivery(circuit_damage, fluid_label)
  local matches = {}
  for _, row in pairs(self.entries) do
    local fluid_ok = fluid_label == nil or row.fluid_label == fluid_label
    local circuit_ok = circuit_damage == nil or row.circuit_damage == circuit_damage
    if fluid_ok and circuit_ok then matches[#matches + 1] = row end
  end
  return matches
end

function BrokerRegistry:load(path)
  path = path or self.config.registry_path
  if not path then return false end
  local rows = RegistryStore.load(path)
  if not rows then return false end
  for key, row in pairs(rows) do
    if type(row) == "table" and type(row.recipe_uid) == "number" then
      self.entries[key] = row
      self.by_uid[row.recipe_uid] = key
    end
  end
  return true
end

function BrokerRegistry:save(path)
  path = path or self.config.registry_path
  if not path then return false, "no registry_path" end
  return RegistryStore.save(path, self.entries)
end

return BrokerRegistry
