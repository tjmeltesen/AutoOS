--[[
  AutoOS — Per-lane side helpers (Array Watch + legacy dispatch)

  Two distinct side systems:
    * Transposer faces (0-5 from the transposer's point of view):
        side_buffer / recover_side — buffer/chest face for staged and returned circuits
        side_bus_b / item_bus_side — dedicated GT input bus face
        side_return                — optional distinct return destination face
        interface_item_side        — legacy dispatch alias
        fluid_pull_side      — legacy dispatch: face stocked fluid is pulled from
        fluid_push_side      — legacy dispatch: face touching GT fluid hatch
    * ME interface block faces (0-5 from the interface's point of view):
        interface_fluid_side — legacy dispatch-only fluid config face
]]

local LaneSides = {}

---@param m table
---@return number
function LaneSides.buffer_side(m)
  if type(m.side_buffer) == "number" then return m.side_buffer end
  if type(m.recover_side) == "number" then return m.recover_side end
  return LaneSides.interface_item_side(m)
end

---@param m table
---@return number
function LaneSides.bus_side(m)
  if type(m.side_bus_b) == "number" then return m.side_bus_b end
  if type(m.item_bus_side) == "number" then return m.item_bus_side end
  return 0
end

---@param m table
---@return number
function LaneSides.return_side(m)
  if type(m.side_return) == "number" then return m.side_return end
  return LaneSides.buffer_side(m)
end

---@param m table
---@return number|nil
function LaneSides.return_slot(m)
  if type(m.return_slot) == "number" and m.return_slot >= 1 then return m.return_slot end
  if type(m.recover_slot) == "number" and m.recover_slot >= 1 then return m.recover_slot end
  return nil
end

--- Transposer face touching the ME interface (items). Default top = 1.
---@param m table machine row
---@return number
function LaneSides.interface_item_side(m)
  if type(m.interface_item_side) == "number" then return m.interface_item_side end
  return 1
end

--- Transposer face used to dump recovered circuits into ME interface.
---@param m table
---@return number
function LaneSides.recover_side(m)
  return LaneSides.return_side(m)
end

--- Slot on recover side where recovered circuit is inserted.
---@param m table
---@return number
function LaneSides.recover_slot(m)
  if type(m.return_slot) == "number" and m.return_slot >= 1 then return m.return_slot end
  if type(m.recover_slot) == "number" and m.recover_slot >= 1 then return m.recover_slot end
  if type(m.interface_item_slot) == "number" and m.interface_item_slot >= 1 then return m.interface_item_slot end
  return 1
end

--- Transposer face touching the GT item input bus. Default bottom = 0.
---@param m table
---@return number
function LaneSides.item_bus_side(m)
  return LaneSides.bus_side(m)
end

--- ME interface block face used for setFluidInterfaceConfiguration. Default bottom = 0.
---@param m table
---@return number
function LaneSides.interface_fluid_side(m)
  if type(m.interface_fluid_side) == "number" then return m.interface_fluid_side end
  return 0
end

--- Transposer face to pull stocked fluid from. Defaults to the interface item face.
---@param m table
---@return number
function LaneSides.fluid_pull_side(m)
  if type(m.fluid_pull_side) == "number" then return m.fluid_pull_side end
  return LaneSides.interface_item_side(m)
end

--- Transposer face touching the GT fluid input hatch. Default back = 2.
---@param m table
---@return number
function LaneSides.fluid_push_side(m)
  if type(m.fluid_push_side) == "number" then return m.fluid_push_side end
  return 2
end

--- All four transposer-relevant sides as plain integers (safe for string.format %d).
---@param m table
---@return number iface_side, number bus_side, number fluid_pull, number fluid_push
function LaneSides.format_sides(m)
  return
    LaneSides.interface_item_side(m),
    LaneSides.item_bus_side(m),
    LaneSides.fluid_pull_side(m),
    LaneSides.fluid_push_side(m)
end

return LaneSides
