--[[
  AutoOS — JobManifest data class
  Immutable-ish recipe manifest: items, fluids, ordered queue.
  Queue entries get db_slot/db_address mutated in-place by job_factory.
]]
local C = require("rob_core.constants")

local JobManifest = {}
JobManifest.__index = JobManifest

--- Normalize a fluid label for comparison (lowercase, strip prefixes).
function JobManifest.norm_fluid_label(s)
  if type(s) ~= "string" then return nil end
  s = s:lower()
  s = s:gsub("^drop of ", "")
  s = s:gsub("^molten ", "")
  return s
end

--- Build a manifest from central chest + central tank contents.
--- @param registry table  cached proxies and config pointers
--- @param config table    validated Config
--- @param fluid_tanks_mod module  FluidTanks module
--- @param yield_fn function|nil  optional yield callback
--- @return table { items={...}, fluids={...}, queue={...} }
function JobManifest.build(registry, config, fluid_tanks_mod, yield_fn)
  local adapter = registry.central_item_adapter
  if not adapter then return { items = {}, fluids = {}, queue = {} } end
  local side = registry.central_item_side
  if type(side) ~= "number" then return { items = {}, fluids = {}, queue = {} } end

  local out = { items = {}, fluids = {}, queue = {} }
  local seen_fluids = {}
  local start = registry.chest_slot_start or config.chest_slot_start or 1

  local ok_size, size = pcall(adapter.getInventorySize, side)
  if not ok_size or type(size) ~= "number" then
    size = start + 53  -- inventory_controller may lie about size
  end

  local function read_stack(slot)
    if not adapter then return nil end
    local ok, st = pcall(adapter.getStackInSlot, side, slot)
    if not ok or type(st) ~= "table" then return nil end
    if (st.size or 0) < 1 then return nil end
    return st
  end

  for slot = start, size do
    if slot % 10 == 0 and yield_fn then yield_fn() end
    local st = read_stack(slot)
    if st then
      if st.name == C.FLUID_DROP_ITEM then
        local fluid_label = st.label and st.label:gsub("^drop of ", "") or nil
        local fluid_spec = {
          fluid_label = fluid_label,
          fluid_filter = { name = st.name, damage = st.damage or 0, label = st.label },
        }
        out.fluids[#out.fluids + 1] = fluid_spec
        out.queue[#out.queue + 1] = {
          kind = "fluid",
          fluid_label = fluid_label,
          fluid_filter = fluid_spec.fluid_filter,
          fluid_source = "chest_drop",
          slot = slot,
        }
        local key = JobManifest.norm_fluid_label(fluid_label)
        if key then seen_fluids[key] = true end
      else
        local item_spec = {
          slot = slot,
          name = st.name,
          damage = st.damage or 0,
          label = st.label,
          count = st.size or 1,
        }
        out.items[#out.items + 1] = item_spec
        out.queue[#out.queue + 1] = {
          kind = "item",
          slot = slot,
          name = item_spec.name,
          damage = item_spec.damage,
          label = item_spec.label,
          count = item_spec.count,
        }
      end
    end
  end

  -- Append central tank fluids not already present as chest drops
  if fluid_tanks_mod then
    local tank_fluids = JobManifest._read_central_tank(registry, config, fluid_tanks_mod)
    for _, fluid in ipairs(tank_fluids) do
      local key = JobManifest.norm_fluid_label(fluid.fluid_label)
      if not key or not seen_fluids[key] then
        out.fluids[#out.fluids + 1] = fluid
        out.queue[#out.queue + 1] = {
          kind = "fluid",
          fluid_label = fluid.fluid_label,
          fluid_registry = fluid.fluid_registry,
          fluid_amount_mb = fluid.fluid_amount_mb,
          fluid_source = fluid.fluid_source,
          fluid_tank_index = fluid.fluid_tank_index,
        }
        if key then seen_fluids[key] = true end
      end
    end
  end

  return out
end

--- Read non-empty central tank fluids.
function JobManifest._read_central_tank(registry, config, fluid_tanks_mod)
  local adapter = registry.central_fluid_adapter
  if not adapter then return {} end
  local side = registry.central_fluid_side
  if type(side) ~= "number" then return {} end

  local c = config.central or {}
  local label_map = type(c.fluid_label_map) == "table" and c.fluid_label_map or {}
  local out = {}

  for _, row in ipairs(fluid_tanks_mod.non_empty_tanks(adapter, side)) do
    local raw = tostring(row.name or "")
    local mapped = label_map[raw] or label_map[JobManifest.norm_fluid_label(raw)] or raw
    out[#out + 1] = {
      fluid_label = mapped,
      fluid_registry = JobManifest.norm_fluid_label(raw) or raw,
      fluid_amount_mb = row.amount,
      fluid_source = "central_tank",
      fluid_tank_index = row.idx,
    }
  end
  return out
end

--- True if the manifest has any work to do.
function JobManifest.has_work(manifest)
  return manifest
    and ((type(manifest.items) == "table" and #manifest.items > 0)
      or (type(manifest.fluids) == "table" and #manifest.fluids > 0)
      or (type(manifest.queue) == "table" and #manifest.queue > 0))
end

return JobManifest
