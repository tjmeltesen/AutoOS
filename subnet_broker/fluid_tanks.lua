--[[
  AutoOS - shared fluid tank helpers for transposer/adapter compatibility.

  Supports OC APIs that expose either:
    - getTankLevel(side, tankIndex)
    - getTankLevel(side)
    - getFluidInTank(side)
]]

local FluidTanks = {}

local function lower(s)
  return type(s) == "string" and string.lower(s) or nil
end

local function normalize_label(s)
  s = lower(s)
  if not s then return nil end
  s = s:gsub("^drop of ", "")
  s = s:gsub("^molten ", "")
  return s
end

function FluidTanks.fluid_rows(dev, side)
  if not dev or not dev.getFluidInTank then return {} end
  local ok, tanks = pcall(dev.getFluidInTank, side)
  if not ok or type(tanks) ~= "table" then return {} end
  if tanks.amount ~= nil then tanks = { tanks } end

  local rows = {}
  for i, t in ipairs(tanks) do
    if type(t) == "table" then
      rows[#rows + 1] = {
        idx = i,
        name = t.name or t.label or t.id or "unknown",
        amount = tonumber(t.amount) or 0,
      }
    end
  end
  return rows
end

function FluidTanks.tank_level(dev, side)
  if not dev then return 0 end
  if dev.getTankLevel then
    local ok, lvl = pcall(dev.getTankLevel, side, 1)
    -- ponytail: don't trust getTankLevel(side,1) when it returns 0 —
    -- the fluid may be in a different tank index (dual IF has 6+ slots).
    if ok and type(lvl) == "number" and lvl > 0 then return lvl end
    ok, lvl = pcall(dev.getTankLevel, side)
    if ok and type(lvl) == "number" and lvl > 0 then return lvl end
  end

  local total = 0
  for _, row in ipairs(FluidTanks.fluid_rows(dev, side)) do
    if row.amount > 0 then total = total + row.amount end
  end
  return total
end

function FluidTanks.tank_capacity(dev, side)
  if not dev or not dev.getTankCapacity then return nil end
  local ok, cap = pcall(dev.getTankCapacity, side, 1)
  if ok and type(cap) == "number" then return cap end
  ok, cap = pcall(dev.getTankCapacity, side)
  if ok and type(cap) == "number" then return cap end
  return nil
end

function FluidTanks.non_empty_tanks(dev, side)
  local out = {}
  for _, row in ipairs(FluidTanks.fluid_rows(dev, side)) do
    if row.amount > 0 then out[#out + 1] = row end
  end
  return out
end

function FluidTanks.buffer_empty(dev, side)
  return FluidTanks.tank_level(dev, side) <= 0
end

function FluidTanks.label_matches(actual, expected)
  local a = normalize_label(actual)
  local e = normalize_label(expected)
  if not a or not e then return false end
  if a == e then return true end
  -- ponytail: substring match only at start of string, not mid-word.
  -- "titanium" should NOT match "titan", but "liquid_oxygen" should match "oxygen".
  if a:find(e, 1, true) == 1 then return true end
  if e:find(a, 1, true) == 1 then return true end
  return false
end

return FluidTanks