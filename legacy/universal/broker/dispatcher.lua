--[[
  Universal Craft Brokers — capability-based dispatcher (pure logic).

  Product → recipe registry → machine_type + tools → eligible idle machine.
]]

local RecipeRegistry = require("shared.recipe_registry")

local Dispatcher = {}

local function has_capability(multi, machine_type)
  if type(multi.capabilities) ~= "table" then
    return false
  end
  for _, cap in ipairs(multi.capabilities) do
    if cap == machine_type then
      return true
    end
  end
  return false
end

local function machine_busy(state)
  if type(state) ~= "table" then
    return false
  end
  if state.available == false then
    return true
  end
  if state.maintenance_fault then
    return true
  end
  if state.active then
    return true
  end
  if state.has_work then
    return true
  end
  return false
end

-- multis: config table array; cache.machines[id] = polled state.
-- Returns machine_id, reason_or_nil on failure.
function Dispatcher.pick(label, multis, cache)
  local recipe = RecipeRegistry.lookup(label)
  if not recipe then
    return nil, "unknown_recipe"
  end

  local machine_type = recipe.machine_type
  local required_tools = recipe.tools or {}

  if type(multis) ~= "table" then
    return nil, "no_available_machine"
  end

  for _, multi in ipairs(multis) do
    if has_capability(multi, machine_type)
        and RecipeRegistry.has_tools(multi.installed_tools, required_tools) then
      local state = cache and cache.machines and cache.machines[multi.id]
      if not machine_busy(state) then
        return multi.id, nil
      end
    end
  end

  return nil, "no_available_machine"
end

return Dispatcher
