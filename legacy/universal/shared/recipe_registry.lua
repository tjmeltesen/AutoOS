--[[
  Universal Craft Brokers — recipe registry (single source of truth).

  Maps product labels to manufacturing requirements. Coordinator validates
  labels; broker dispatcher reads machine_type + tools for routing.
]]

local RECIPES = {
  Benzene = {
    machine_type = "distillation_tower",
    tools = { "Circuit24" },
  },
  Toluene = {
    machine_type = "distillation_tower",
    tools = { "Circuit25" },
  },
  SulfuricAcid = {
    machine_type = "chemical_reactor",
    tools = { "Circuit6" },
  },
}

local RecipeRegistry = {}

function RecipeRegistry.lookup(label)
  if not label then return nil end
  return RECIPES[label]
end

function RecipeRegistry.known(label)
  return RECIPES[label] ~= nil
end

-- Returns shallow copy for tests / introspection.
function RecipeRegistry.all()
  local out = {}
  for k, v in pairs(RECIPES) do
    out[k] = v
  end
  return out
end

-- Check multi.installed_tools contains every required tool (declarative v1).
function RecipeRegistry.has_tools(installed, required)
  if type(required) ~= "table" or #required == 0 then
    return true
  end
  if type(installed) ~= "table" then
    return false
  end
  local have = {}
  for _, t in ipairs(installed) do
    have[t] = true
  end
  for _, t in ipairs(required) do
    if not have[t] then
      return false
    end
  end
  return true
end

return RecipeRegistry
