--[[
  AutoOS — Fluid lane delivery (ME interface stocking → transposer → hatch)

  The ME interface keeps only a small buffer stocked, so a lane must PUMP:
  repeat transferFluid until the full allocated volume reaches the hatch.

  Side discovery: the configured sides are tried first; if nothing moves we
  probe other ME faces / transposer pull faces ONCE, then cache the working
  combination per lane for the rest of the session.

  Probing is done with transferFluid itself (moved > 0 == correct sides) —
  tank inspection APIs throw "invalid tank index" on faces without tanks,
  so they are only used (pcall-guarded) for diagnostics.
]]

local HW = require("hw")
local LaneSides = require("lane_sides")

local FluidLane = {}

-- Per-lane discovered sides: { [machine_id] = { me_side = n, pull_side = n } }
local side_cache = {}

local PUMP_STALL_LIMIT = 8     -- consecutive zero-move attempts before giving up
local PUMP_STALL_SLEEP = 0.25  -- seconds between stalled attempts
local PROBE_ATTEMPTS = 3       -- attempts per side combination while probing

--- Normalize transferFluid's (boolean, number|string) / (number) returns.
---@return number moved
---@return string|nil err
local function normalize_transfer(r1, r2)
  if r1 == true then
    return type(r2) == "number" and r2 or 0, nil
  end
  if r1 == false then
    return 0, type(r2) == "string" and r2 or nil
  end
  if type(r1) == "number" then
    return r1, nil
  end
  return 0, nil
end

--- mB visible on a transposer face (0 when the face has no tank).
---@param tp table
---@param side number
---@return number
function FluidLane.fluid_mb_on_side(tp, side)
  if not tp or not tp.getTankLevel then return 0 end
  local tanks = 1
  if tp.getTankCount then
    local ok, n = pcall(tp.getTankCount, side)
    if ok and type(n) == "number" then tanks = n end
  end
  local max_mb = 0
  for t = 1, math.max(tanks, 1) do
    local ok, lvl = pcall(tp.getTankLevel, side, t)
    if ok and type(lvl) == "number" and lvl > max_mb then max_mb = lvl end
  end
  return max_mb
end

--- Human-readable tank levels across all transposer faces (diagnostics only).
---@param tp table
---@return string
function FluidLane.transposer_tank_summary(tp)
  if not tp or not tp.getTankLevel then return "getTankLevel unavailable" end
  local parts = {}
  for s = 0, 5 do
    local lvl = FluidLane.fluid_mb_on_side(tp, s)
    if lvl > 0 then
      parts[#parts + 1] = string.format("side %d=%dmB", s, lvl)
    end
  end
  if #parts == 0 then return "all transposer faces empty" end
  return table.concat(parts, ", ")
end

--- Pump from pull_side to push_side until `volume` mB moved or progress stalls.
---@return number moved_total
---@return string|nil last_err
local function pump(tp, pull_side, push_side, volume, max_attempts)
  local moved_total = 0
  local stall = 0
  local last_err = nil
  local attempts = 0
  while moved_total < volume do
    attempts = attempts + 1
    if max_attempts and attempts > max_attempts then break end
    local r1, r2 = tp.transferFluid(pull_side, push_side, volume - moved_total)
    local moved, err = normalize_transfer(r1, r2)
    if err then last_err = err end
    if moved >= 1 then
      moved_total = moved_total + moved
      stall = 0
    else
      stall = stall + 1
      if stall >= PUMP_STALL_LIMIT then break end
      HW.sleep(PUMP_STALL_SLEEP)
    end
  end
  return moved_total, last_err
end

--- Candidate list: configured value first, then remaining 0-5 (minus exclusions).
local function candidates(preferred, exclude)
  local list, seen = {}, {}
  local function add(s)
    if s ~= nil and not seen[s] and s ~= exclude then
      seen[s] = true
      list[#list + 1] = s
    end
  end
  add(preferred)
  for s = 0, 5 do add(s) end
  return list
end

--- Deliver `volume` mB of the configured fluid into the lane's hatch.
---@param iface table lane me_interface proxy
---@param tp table lane transposer proxy
---@param db_addr string OC database address
---@param db_slot integer database slot holding the fluid drop descriptor
---@param machine table machine config row
---@param volume number mB to deliver
---@return boolean ok
---@return number moved_total
---@return string|nil err
function FluidLane.deliver(iface, tp, db_addr, db_slot, machine, volume)
  if not tp.transferFluid then
    return false, 0, "transposer has no transferFluid"
  end
  if not iface.setFluidInterfaceConfiguration then
    return false, 0, "me_interface has no setFluidInterfaceConfiguration"
  end

  local push_side = LaneSides.fluid_push_side(machine)
  local cached = side_cache[machine.id]
  local me_pref = cached and cached.me_side or LaneSides.interface_fluid_side(machine)
  local pull_pref = cached and cached.pull_side or LaneSides.fluid_pull_side(machine)

  for _, me_side in ipairs(candidates(me_pref)) do
    local ok_cfg = iface.setFluidInterfaceConfiguration(me_side, db_addr, db_slot)
    if ok_cfg then
      HW.sleep(0.25)  -- let AE2 stock the interface buffer

      for _, pull_side in ipairs(candidates(pull_pref, push_side)) do
        -- Short probe: does anything move with this combination?
        local probe_moved = pump(tp, pull_side, push_side, volume, PROBE_ATTEMPTS)
        if probe_moved >= 1 then
          -- Correct sides found — lock them in and pump the remainder.
          side_cache[machine.id] = { me_side = me_side, pull_side = pull_side }
          local rest, rest_err = 0, nil
          if probe_moved < volume then
            rest, rest_err = pump(tp, pull_side, push_side, volume - probe_moved)
          end
          local total = probe_moved + rest
          iface.setFluidInterfaceConfiguration(me_side)
          if total >= volume then
            return true, total, nil
          end
          return false, total, string.format(
            "delivered %d of %d mB then stalled (ME side %d, transposer %d→%d)%s — subnet ran dry?",
            total, volume, me_side, pull_side, push_side,
            rest_err and (": " .. rest_err) or ""
          )
        end
      end

      iface.setFluidInterfaceConfiguration(me_side)
    end
  end

  return false, 0, string.format(
    "no fluid moved on any side combination (hatch side %d, %s) — fluid drop descriptor may be empty or interface not stocking",
    push_side, FluidLane.transposer_tank_summary(tp)
  )
end

--- Forget cached sides (e.g. after physically rearranging a lane).
---@param machine_id string|nil nil clears all lanes
function FluidLane.reset_cache(machine_id)
  if machine_id then
    side_cache[machine_id] = nil
  else
    side_cache = {}
  end
end

--- Currently cached sides for a lane (for diag display).
---@param machine_id string
---@return table|nil
function FluidLane.cached_sides(machine_id)
  return side_cache[machine_id]
end

return FluidLane
