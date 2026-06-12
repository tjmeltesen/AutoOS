--[[
  AutoOS — Dynamic ME → OC database descriptors

  Fills scratch database slots at runtime so no manual database GUI setup is
  needed:
    * circuits — me.store() from subnet ME, database.set() fallback
    * fluids   — me.store() of the AE2FC fluid drop item ("drop of <Fluid>")

  IMPORTANT: setFluidInterfaceConfiguration needs an ae2fc fluid drop in the
  database slot. Drops only exist as ME items when a Fluid Discretizer is on
  the subnet. We verify the slot after storing and report a precise error.

  References: CommonNetworkAPI.store, database, me_interface.lua,
              references/autoos-api-mapping.md (drop label format)
]]

local HW = require("hw")

local DescriptorCache = {}
DescriptorCache.__index = DescriptorCache

local DEFAULT_CIRCUIT_ITEM = "gregtech:gt.integrated_circuit"
local FLUID_DROP_ITEM = "ae2fc:fluid_drop"

function DescriptorCache.new(deps)
  deps = deps or {}
  local self = setmetatable({}, DescriptorCache)
  self.config = deps.config or error("DescriptorCache.new: config required")
  self.component = deps.component or error("DescriptorCache.new: component required")
  return self
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

--- Read back a database slot (nil when database proxy or get unavailable).
function DescriptorCache:_db_entry(slot)
  local db = HW.proxy(self.component, self:_database_address(), "database")
  if not db or not db.get then return nil end
  local ok, entry = pcall(db.get, slot)
  if ok and type(entry) == "table" then return entry end
  return nil
end

-- ---------------------------------------------------------------- circuits

--- Write a circuit descriptor to the circuit scratch slot.
---@param iface table lane me_interface proxy
---@param circuit_damage integer programmed circuit configuration (= damage)
---@return boolean ok
---@return integer|string slot_or_err
function DescriptorCache:ensure_circuit(iface, circuit_damage)
  local db_addr = self:_database_address()
  if not db_addr or db_addr == "" then
    return false, "database_address not configured"
  end

  local slot = select(1, self:_scratch_slots())
  local item_name = self:_circuit_item_name()

  if iface and iface.store then
    local ok_store = iface.store({ name = item_name, damage = circuit_damage }, db_addr, slot, 1)
    if ok_store then
      return true, slot
    end
  end

  -- Circuit not visible in subnet ME — synthesize the descriptor directly.
  local db = HW.proxy(self.component, db_addr, "database")
  if db and db.set then
    local ok_set, set_err = pcall(db.set, slot, item_name, circuit_damage)
    if ok_set and set_err ~= false then
      return true, slot
    end
    return false, "database.set circuit failed: " .. tostring(set_err)
  end

  return false, string.format(
    "circuit %s not in subnet ME and database.set unavailable",
    tostring(circuit_damage)
  )
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

--- Write a fluid drop descriptor to the fluid scratch slot.
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

  local slot = select(2, self:_scratch_slots())
  local hint = tostring(rules.fluid_label or rules.fluid_registry or "?")

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

  local ok_store = iface.store(filter, db_addr, slot, 1)
  if not ok_store then
    return false, string.format("me.store failed for fluid drop %q", hint)
  end

  -- Verify the slot really holds a fluid drop; a bad descriptor stocks nothing.
  local entry = self:_db_entry(slot)
  if entry and entry.name and not entry.name:find("fluid_drop", 1, true) then
    return false, string.format(
      "database slot %d holds %q, expected an %s — fluid config would stock nothing",
      slot, tostring(entry.name), FLUID_DROP_ITEM
    )
  end

  return true, slot
end

return DescriptorCache
