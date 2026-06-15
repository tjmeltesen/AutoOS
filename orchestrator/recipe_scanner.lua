--[[
  AutoOS — AE2 pattern scanner

  Discovers autocraft patterns via filtered getCraftables (never every tick).
  Uses fluids present on the ME network plus optional extra labels as scan seeds.

  Registry must implement :add(recipe_key, rule, source) -> ok, err, is_new
]]

local RecipeScanner = {}

local function cfg_get(cfg, key)
  if not cfg then return nil end
  if cfg[key] ~= nil then return cfg[key] end
  local o = cfg.orchestrator
  if o and o[key] ~= nil then return o[key] end
  local c = cfg.constraints
  if c and c[key] ~= nil then return c[key] end
  return nil
end

local function slug(label)
  if type(label) ~= "string" or label == "" then return "unknown" end
  return label:lower():gsub("[^%w]+", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
end

local function as_craftable_list(craftables)
  if type(craftables) ~= "table" then return {} end
  if craftables.getItemStack or craftables.request then return { craftables } end
  return craftables
end

local function craftables_for_label(me, label)
  if not me or not me.getCraftables or not label or label == "" then return {} end
  local seen, out = {}, {}
  local filters = { label }
  if not label:find("^drop of ", 1, true) then
    filters[#filters + 1] = "drop of " .. label
  end
  for _, filt in ipairs(filters) do
    local ok, list = pcall(me.getCraftables, { label = filt })
    if ok then
      for _, c in ipairs(as_craftable_list(list)) do
        local stack = c.getItemStack and c.getItemStack()
        local key = stack and (stack.label or stack.name) or filt
        if key and not seen[key] then
          seen[key] = true
          out[#out + 1] = { craftable = c, stack = stack, filter_label = filt }
        end
      end
    end
  end
  return out
end

local function collect_seed_labels(me, registry, extra)
  local labels = {}
  if me.getFluidsInNetwork then
    local ok, fluids = pcall(me.getFluidsInNetwork)
    if ok and type(fluids) == "table" then
      for _, f in ipairs(fluids) do
        if f.label and f.label ~= "" then labels[f.label] = true end
      end
    end
  end
  if registry and registry.entries then
    for _, row in pairs(registry.entries) do
      if row.fluid_label then labels[row.fluid_label] = true end
    end
  end
  for _, lab in ipairs(extra or {}) do
    if type(lab) == "string" and lab ~= "" then labels[lab] = true end
  end
  return labels
end

--- Scan AE patterns and merge into registry.
---@param me table ME proxy with getCraftables
---@param registry table broker registry
---@param opts table|nil { config, extra_labels, default_fluid_requirement, now, log, full_scan }
---@return number added, number updated
function RecipeScanner.scan(me, registry, opts)
  opts = opts or {}
  local log = opts.log or function() end
  local now = opts.now or 0
  local cfg = opts.config or {}
  local default_req = opts.default_fluid_requirement
    or cfg_get(cfg, "default_fluid_requirement")
    or 1000

  local added, updated = 0, 0
  local labels = collect_seed_labels(me, registry, opts.extra_labels or cfg_get(cfg, "pattern_scan_extra_labels"))

  if cfg_get(cfg, "pattern_scan_full") and me.getCraftables then
    local ok, all = pcall(me.getCraftables)
    if ok then
      for _, c in ipairs(as_craftable_list(all)) do
        local stack = c.getItemStack and c.getItemStack()
        if stack and stack.label then labels[stack.label] = true end
      end
    end
  end

  for label in pairs(labels) do
    for _, hit in ipairs(craftables_for_label(me, label)) do
      local stack = hit.stack
      local fluid_label = stack and stack.label or label
      local recipe_key = slug(fluid_label)
      local rule = {
        display_name = fluid_label,
        fluid_label = fluid_label,
        fluid_requirement = default_req,
        craftable = true,
        last_scan = now,
      }
      local existed = registry.entries[recipe_key]
      local ok, err = registry:add(recipe_key, rule, "ae_scan")
      if ok then
        if not existed then
          added = added + 1
          log(string.format("[scan] new pattern: %s (uid=%s)", recipe_key,
            tostring(registry.entries[recipe_key].recipe_uid)))
        else
          updated = updated + 1
        end
      else
        log("[scan] skip " .. recipe_key .. ": " .. tostring(err))
      end
    end
  end

  return added, updated
end

return RecipeScanner
