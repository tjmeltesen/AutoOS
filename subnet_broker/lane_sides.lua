--[[
  AutoOS — Per-lane side helpers (LCR dual-transposer topology)

  Item transposer: side_buffer, side_bus_b, side_return
  Fluid transposer: side_fluid_buffer (default side_buffer), side_fluid_hatch
]]

local LaneSides = {}

function LaneSides.buffer_side(m)
  if type(m.side_buffer) == "number" then return m.side_buffer end
  return 1
end

function LaneSides.bus_side(m)
  if type(m.side_bus_b) == "number" then return m.side_bus_b end
  if type(m.item_bus_side) == "number" then return m.item_bus_side end
  return 0
end

function LaneSides.return_side(m)
  if type(m.side_return) == "number" then return m.side_return end
  return LaneSides.buffer_side(m)
end

function LaneSides.return_slot(m)
  if type(m.return_slot) == "number" and m.return_slot >= 1 then return m.return_slot end
  return nil
end

function LaneSides.fluid_buffer_side(m)
  if type(m.side_fluid_buffer) == "number" then return m.side_fluid_buffer end
  return LaneSides.buffer_side(m)
end

function LaneSides.fluid_hatch_side(m)
  if type(m.side_fluid_hatch) == "number" then return m.side_fluid_hatch end
  if type(m.fluid_push_side) == "number" then return m.fluid_push_side end
  return LaneSides.bus_side(m)
end

function LaneSides.item_transposer_address(m)
  return m.item_transposer_address or m.transposer_address
end

function LaneSides.fluid_transposer_address(m)
  return m.fluid_transposer_address
end

return LaneSides
