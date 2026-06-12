--[[
  AutoOS — Fluid lane helpers (ME interface stocking + transposer discovery)

  setFluidInterfaceConfiguration uses ME interface block faces; transferFluid uses
  transposer faces. They are not the same index — probe tanks after stocking.
]]

local FluidLane = {}

--- Millibuckets on one transposer face (safe when side has no tank handler).
---@param tp table
---@param side number
---@return number
function FluidLane.fluid_mb_on_side(tp, side)
  if not tp or not tp.getTankLevel then return 0 end

  local tank_count = 1
  if tp.getTankCount then
    local ok, n = pcall(tp.getTankCount, side)
    if ok and type(n) == "number" then
      tank_count = n
    end
  end
  if tank_count < 1 then return 0 end

  local max_mb = 0
  -- OC transposer tanks are 1-based on GTNH; also try 0-based if needed.
  for t = 1, tank_count do
    local ok, lvl = pcall(tp.getTankLevel, side, t)
    if ok and type(lvl) == "number" and lvl > max_mb then
      max_mb = lvl
    end
  end
  if max_mb < 1 and tank_count > 0 then
    for t = 0, tank_count - 1 do
      local ok, lvl = pcall(tp.getTankLevel, side, t)
      if ok and type(lvl) == "number" and lvl > max_mb then
        max_mb = lvl
      end
    end
  end
  return max_mb
end

---@param tp table transposer proxy
---@param min_mb number
---@param max_attempts integer
---@return number|nil transposer_side
function FluidLane.find_fluid_on_transposer(tp, min_mb, max_attempts)
  if not tp or not tp.getTankLevel then return nil end
  min_mb = min_mb or 1
  max_attempts = max_attempts or 12
  for _ = 1, max_attempts do
    for s = 0, 5 do
      if FluidLane.fluid_mb_on_side(tp, s) >= min_mb then
        return s
      end
    end
    if os and os.sleep then os.sleep(0.25) end
  end
  for s = 0, 5 do
    if FluidLane.fluid_mb_on_side(tp, s) > 0 then
      return s
    end
  end
  return nil
end

--- Stock fluid via ME interface; return ME side and transposer pull side that has fluid.
---@return number|nil me_side
---@return number|nil pull_side
---@return string|nil err
function FluidLane.stock_and_locate(iface, tp, db_addr, db_slot, preferred_me_side)
  if not iface or not iface.setFluidInterfaceConfiguration then
    return nil, nil, "setFluidInterfaceConfiguration unavailable"
  end

  local order = {}
  if type(preferred_me_side) == "number" then
    order[#order + 1] = preferred_me_side
  end
  for s = 0, 5 do
    if s ~= preferred_me_side then
      order[#order + 1] = s
    end
  end

  for _, me_side in ipairs(order) do
    local ok_cfg = iface.setFluidInterfaceConfiguration(me_side, db_addr, db_slot)
    if ok_cfg then
      local pull_side = FluidLane.find_fluid_on_transposer(tp, 1, 8)
      if pull_side then
        return me_side, pull_side, nil
      end
      iface.setFluidInterfaceConfiguration(me_side)
    end
  end

  return nil, nil, "no fluid on transposer after ME stocking"
end

---@param tp table
---@return string
function FluidLane.transposer_tank_summary(tp)
  if not tp or not tp.getTankLevel then
    return "getTankLevel unavailable"
  end
  local parts = {}
  for s = 0, 5 do
    local lvl = FluidLane.fluid_mb_on_side(tp, s)
    if lvl > 0 then
      parts[#parts + 1] = string.format("%d=%dmB", s, lvl)
    end
  end
  if #parts == 0 then
    return "all transposer sides empty"
  end
  return table.concat(parts, ", ")
end

---@param tp table
---@param side number
---@return string
function FluidLane.fluid_tank_hint(tp, side)
  local lvl = FluidLane.fluid_mb_on_side(tp, side)
  if lvl > 0 then
    return string.format("side %d has %d mB", side, lvl)
  end
  return "side " .. tostring(side) .. " tank empty"
end

return FluidLane
