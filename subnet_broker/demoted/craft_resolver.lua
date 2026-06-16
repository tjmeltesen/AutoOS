--[[
  AutoOS — Craft resolver (broker deploy copy)

  UID token delta is authoritative; circuit+fluid is fallback only.
]]

local CraftResolver = {}

local function volume_for(row, fluids, token_count)
  if row.fluid_label then
    local fl = (fluids or {})[row.fluid_label]
    if fl and fl > 0 then return fl end
  end
  if row.default_dispatch_mB and row.default_dispatch_mB > 0 then
    return row.default_dispatch_mB
  end
  if token_count and token_count > 0 then
    return token_count * (row.fluid_requirement or 0)
  end
  return 0
end

function CraftResolver.resolve(deltas, registry)
  deltas = deltas or {}
  local tokens = deltas.tokens or {}
  local circuits = deltas.circuits or {}
  local fluids = deltas.fluids or {}

  local best_uid, best_n
  for uid, n in pairs(tokens) do
    if registry:resolve_uid(uid) and (not best_n or n > best_n) then
      best_uid, best_n = uid, n
    end
  end
  if best_uid then
    local row = registry:resolve_uid(best_uid)
    return {
      matched = true, fault = false,
      recipe_key = row.recipe_key, row = row, recipe_uid = best_uid,
      volume_mB = volume_for(row, fluids, best_n), source = "uid",
    }
  end

  local candidates, picked_label = {}, nil
  for label, _ in pairs(fluids) do
    for _, row in ipairs(registry:resolve_delivery(nil, label)) do
      local circuit_seen = next(circuits) == nil
        or row.circuit_damage == nil
        or (circuits[row.circuit_damage] or 0) > 0
      if circuit_seen then
        candidates[#candidates + 1] = row
        picked_label = label
      end
    end
  end

  if #candidates == 1 then
    local row = candidates[1]
    return {
      matched = true, fault = false,
      recipe_key = row.recipe_key, row = row, recipe_uid = row.recipe_uid,
      volume_mB = volume_for(row, fluids, nil), source = "fallback",
    }
  elseif #candidates > 1 then
    return {
      matched = false, fault = true,
      reason = string.format(
        "ambiguous circuit+fluid for %s (%d recipes) — assign recipe_uid to AE pattern",
        tostring(picked_label), #candidates
      ),
    }
  end

  return { matched = false, fault = false }
end

return CraftResolver
