--[[
  AutoOS — Dynamic ME → OC database descriptors

  Fills scratch database slots at runtime from subnet ME storage via me.store(),
  with database.set() fallback for programmed circuits (no manual DB GUI setup).

  References: CommonNetworkAPI.store, database.set, me_interface.lua
]]

local DescriptorCache = {}
DescriptorCache.__index = DescriptorCache

local DEFAULT_CIRCUIT_ITEM = "gregtech:gt.integrated_circuit"
local FLUID_DROP_ITEM = "ae2fc:fluid_drop"

function DescriptorCache.new(deps)
  deps = deps or {}
  local self = setmetatable({}, DescriptorCache)
  self.config = deps.config or error("DescriptorCache.new: config required")
  self.component = deps.component or error("DescriptorCache.new: component required")
  self.proxies = {}
  return self
end

function DescriptorCache:_proxy(address, hint)
  if self.proxies[address] then return self.proxies[address] end
  local ok, proxy = pcall(self.component.proxy, address, hint)
  if not ok or not proxy then
    ok, proxy = pcall(self.component.proxy, address)
  end
  if ok and proxy then
    self.proxies[address] = proxy
    return proxy
  end
  return nil
end

function DescriptorCache:_scratch_slots()
  local scratch = self.config.descriptor_scratch or {}
  return scratch.circuit_slot or 1, scratch.fluid_slot or 2
end

function DescriptorCache:_database_address()
  return self.config.database_address
end

function DescriptorCache:_circuit_item_name()
  return self.config.circuit_item_name or DEFAULT_CIRCUIT_ITEM
end

function DescriptorCache:_legacy_circuit_slot(circuit_damage)
  local slots = self.config.circuit_db_slots
  if slots and slots[circuit_damage] then
    return slots[circuit_damage]
  end
  return nil
end

function DescriptorCache:_legacy_fluid_slot(rules)
  if rules and rules.fluid_db_slot then
    return rules.fluid_db_slot
  end
  return nil
end

--- Write circuit descriptor to scratch slot (from ME or database.set).
---@return boolean ok
---@return integer|string slot_or_err
function DescriptorCache:ensure_circuit(iface, circuit_damage)
  local db_addr = self:_database_address()
  if not db_addr or db_addr == "" then
    return false, "database_address not configured"
  end

  local legacy = self:_legacy_circuit_slot(circuit_damage)
  if legacy then
    return true, legacy
  end

  local slot = select(1, self:_scratch_slots())
  local item_name = self:_circuit_item_name()
  local filter = { name = item_name, damage = circuit_damage }

  if iface and iface.store then
    local ok_store = iface.store(filter, db_addr, slot, 1)
    if ok_store then
      return true, slot
    end
  end

  local db = self:_proxy(db_addr, "database")
  if db and db.set then
    local ok_set, set_err = db.set(slot, item_name, circuit_damage)
    if ok_set then
      return true, slot
    end
    return false, "database.set circuit failed: " .. tostring(set_err)
  end

  return false, "circuit " .. tostring(circuit_damage) .. " not in subnet and database.set unavailable"
end

local function normalize_label(s)
  if type(s) ~= "string" then return nil end
  return s:lower()
end

function DescriptorCache:_fluid_filter_from_rules(iface, rules)
  if type(rules.fluid_filter) == "table" then
    return rules.fluid_filter
  end

  local want_label = normalize_label(rules.fluid_label)

  if iface.getFluidsInNetwork and want_label then
    local fluids = iface.getFluidsInNetwork()
    if type(fluids) == "table" then
      for _, f in ipairs(fluids) do
        if normalize_label(f.label) == want_label then
          if f.name then
            return { name = f.name, damage = f.damage or 0, tag = f.tag }
          end
          if rules.fluid_registry then
            return {
              name = FLUID_DROP_ITEM,
              damage = 0,
              tag = "{Fluid:" .. rules.fluid_registry .. "}",
            }
          end
        end
      end
    end
  end

  if iface.getItemsInNetwork then
    if rules.fluid_registry then
      local tag = "{Fluid:" .. rules.fluid_registry .. "}"
      local stacks = iface.getItemsInNetwork({ name = FLUID_DROP_ITEM, damage = 0, tag = tag })
      if stacks and stacks[1] then
        local it = stacks[1]
        return { name = it.name, damage = it.damage or 0, tag = it.tag }
      end
    end

    if want_label then
      local stacks = iface.getItemsInNetwork({ label = rules.fluid_label })
      if stacks and stacks[1] then
        local it = stacks[1]
        return { name = it.name, damage = it.damage or 0, tag = it.tag }
      end
      stacks = iface.getItemsInNetwork({ name = FLUID_DROP_ITEM })
      if type(stacks) == "table" then
        for _, it in ipairs(stacks) do
          if normalize_label(it.label) == want_label then
            return { name = it.name, damage = it.damage or 0, tag = it.tag }
          end
        end
      end
    end
  end

  if rules.fluid_registry then
    return {
      name = FLUID_DROP_ITEM,
      damage = 0,
      tag = "{Fluid:" .. rules.fluid_registry .. "}",
    }
  end

  return nil
end

--- Write fluid descriptor to scratch slot from subnet ME.
---@return boolean ok
---@return integer|string slot_or_err
function DescriptorCache:ensure_fluid(iface, rules)
  local db_addr = self:_database_address()
  if not db_addr or db_addr == "" then
    return false, "database_address not configured"
  end

  local legacy = self:_legacy_fluid_slot(rules)
  if legacy then
    return true, legacy
  end

  local slot = select(2, self:_scratch_slots())
  local filter = self:_fluid_filter_from_rules(iface, rules)
  if not filter then
    if not rules.fluid_label and not rules.fluid_registry and not rules.fluid_filter then
      return false, "recipe missing fluid_label or fluid_registry"
    end
    local hint = rules.fluid_label or rules.fluid_registry or "?"
    return false, string.format(
      "fluid %q not found in subnet ME — stock it on this lane's network or fix fluid_label in config",
      hint
    )
  end

  if not iface or not iface.store then
    return false, "me_interface.store unavailable"
  end

  local ok_store = iface.store(filter, db_addr, slot, 1)
  if ok_store then
    return true, slot
  end

  return false, "fluid not in subnet ME (store failed for " .. tostring(rules.fluid_label or rules.fluid_registry) .. ")"
end

return DescriptorCache
