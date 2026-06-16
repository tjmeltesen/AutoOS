--[[
  AutoOS — Craft resolver (thin registry lookup over subnet deltas)

  Resolution priority (plan phase_3_orchestrator):
    1. UID token delta   → registry.by_uid  (AUTHORITATIVE)
    2. circuit + fluid    → registry fallback; ambiguous (>1 row) = FAULT
    3. no match          → nil (orchestrator stays WAITING)

  Stateless: takes deltas from subnet_cache:poll() and an ae_recipe_registry.
]]

local CraftResolver = {}

--- The recipe's delivered volume from the fluid deltas (0 if not seen).
local function volume_for(row, fluids)
  if not row.fluid_label then return 0 end
  return (fluids or {})[row.fluid_label] or 0
end

--- @return table result { matched, fault, recipe_key, row, recipe_uid, volume_mB, reason }
function CraftResolver.resolve(deltas, registry)
  deltas = deltas or {}
  local tokens = deltas.tokens or {}
  local circuits = deltas.circuits or {}
  local fluids = deltas.fluids or {}

  -- 1) UID token delta — pick the uid with the largest positive delta.
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
      volume_mB = volume_for(row, fluids), source = "uid",
    }
  end

  -- 2) Fallback — fluid delta narrowed by circuit delta when available.
  local candidates, picked_label = {}, nil
  for label, _ in pairs(fluids) do
    local rows = registry:resolve_delivery(nil, label)
    for _, row in ipairs(rows) do
      -- Only count a row whose circuit was also just delivered (if we track it).
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
      volume_mB = volume_for(row, fluids), source = "fallback",
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
