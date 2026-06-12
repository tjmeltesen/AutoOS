--[[
  AutoOS — Per-lane transposer side helpers (1:1:1 topology)

  Item input bus: interface and bus share one transposer face (item_bus_side).
  Fluid hatch: separate fluid_pull_side / fluid_push_side.
]]

local LaneSides = {}

---@param m table machine row from config
---@return number|nil
function LaneSides.item_bus_side(m)
  if m.item_bus_side ~= nil then return m.item_bus_side end
  if m.pull_side ~= nil and m.push_side ~= nil and m.pull_side == m.push_side then
    return m.pull_side
  end
  if m.pull_side ~= nil then return m.pull_side end
  return m.push_side
end

---@param m table
---@return number|nil
function LaneSides.fluid_pull_side(m)
  if m.fluid_pull_side ~= nil then return m.fluid_pull_side end
  return LaneSides.item_bus_side(m)
end

return LaneSides
