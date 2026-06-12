--[[
  AutoOS — Per-lane transposer side helpers (1:1:1 topology)

  Items: interface_item_side (ME interface) → item_bus_side (GT input bus).
  Fluids: fluid_pull_side → fluid_push_side (separate hatch face).
]]

local LaneSides = {}

--- ME Interface block face on the transposer (1 = top when interface is above transposer).
---@param m table
---@return number
function LaneSides.interface_item_side(m)
  if type(m.interface_item_side) == "number" then return m.interface_item_side end
  if type(m.pull_side) == "number" then return m.pull_side end
  return 0
end

--- GT item input bus / pipe face (one side for both push and recover on the bus).
---@param m table
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
  if type(m.fluid_pull_side) == "number" then return m.fluid_pull_side end
  return 2
end

---@param m table
---@return number
function LaneSides.fluid_push_side(m)
  if type(m.fluid_push_side) == "number" then return m.fluid_push_side end
  return 2
end

--- Safe integers for string.format (%d rejects nil).
---@param m table
---@return number iface_side, number bus_side, number fluid_pull, number fluid_push
function LaneSides.format_sides(m)
  local bus = LaneSides.item_bus_side(m)
  if type(bus) ~= "number" then bus = -1 end
  return
    LaneSides.interface_item_side(m),
    bus,
    LaneSides.fluid_pull_side(m),
    LaneSides.fluid_push_side(m)
end

return LaneSides
