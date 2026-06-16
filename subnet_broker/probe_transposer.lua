--[[
  AutoOS — Transposer face probe (in-game wiring discovery)

  Run from OC shell:
    loadfile("/home/subnet_broker/probe_transposer.lua")()

  Or one lane:
    loadfile("/home/subnet_broker/probe_transposer.lua")("machine_02")

  Maps every transposer face (0–5): slot count, items, fluid mB.
  Use this to set item_bus_side (circuit found here after a recipe) and
  recover_side (a different face with slots that accepts items → ME import).
]]

local LANE_ID = nil  -- nil = all lanes; or set e.g. "machine_01"

local SIDE_NAMES = {
  [0] = "bottom",
  [1] = "top",
  [2] = "back",
  [3] = "front",
  [4] = "right",
  [5] = "left",
}

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("config")
local component = require("component")

local function is_circuit(stack, circuit_name)
  if type(stack) ~= "table" then return false end
  local name = stack.name or ""
  circuit_name = circuit_name or "integrated_circuit"
  return name == circuit_name or name:find(circuit_name, 1, true) ~= nil
end

local function fluid_mb_on_side(tp, side)
  if not tp.getTankLevel then return nil end
  local tanks = 1
  if tp.getTankCount then
    local ok, n = pcall(tp.getTankCount, side)
    if ok and type(n) == "number" then tanks = n end
  end
  local total = 0
  local any = false
  for t = 1, math.max(tanks, 1) do
    local ok, lvl = pcall(tp.getTankLevel, side, t)
    if ok and type(lvl) == "number" and lvl > 0 then
      total = total + lvl
      any = true
    end
  end
  return any and total or nil
end

local function proxy_transposer(addr)
  local ok, tp = pcall(component.proxy, addr, "transposer")
  if ok and tp then return tp end
  ok, tp = pcall(component.proxy, addr)
  return ok and tp or nil
end

local function print_lane(machine)
  print(string.rep("-", 56))
  print(string.format("[Probe] %s  transposer %s", machine.id, machine.transposer_address))
  print(string.format("  config  item_bus_side=%s  recover_side=%s  recover_slot=%s",
    tostring(machine.item_bus_side), tostring(machine.recover_side), tostring(machine.recover_slot or 1)))

  local tp = proxy_transposer(machine.transposer_address)
  if not tp then
    print("  ERROR: transposer proxy failed — check UUID on component.list()")
    return
  end

  local circuit_name = Config.circuit_item_name or "gregtech:gt.integrated_circuit"
  local faces_with_inv = 0
  local circuit_faces = {}
  local fluid_faces = {}

  for side = 0, 5 do
    local label = SIDE_NAMES[side] or "?"
    local inv_ok, inv_size = pcall(tp.getInventorySize, side)
    inv_size = inv_ok and inv_size or 0
    local fluid_mb = fluid_mb_on_side(tp, side)

    local parts = {}
    if inv_size and inv_size > 0 then
      faces_with_inv = faces_with_inv + 1
      parts[#parts + 1] = string.format("%d item slots", inv_size)
    end
    if fluid_mb then
      parts[#parts + 1] = string.format("%d mB fluid", fluid_mb)
      fluid_faces[#fluid_faces + 1] = side
    end
    if #parts == 0 then
      parts[#parts + 1] = "no inventory / no fluid"
    end

    local markers = {}
    if machine.item_bus_side == side then markers[#markers + 1] = "item_bus_side" end
    if machine.recover_side == side then markers[#markers + 1] = "recover_side" end
    local mark = #markers > 0 and ("  <<" .. table.concat(markers, ", ") .. ">>") or ""

    print(string.format("  side %d (%s): %s%s", side, label, table.concat(parts, ", "), mark))

    if inv_size and inv_size > 0 then
      local shown = 0
      for slot = 1, inv_size do
        local st = tp.getStackInSlot and tp.getStackInSlot(side, slot)
        if st and (st.size or 0) > 0 then
          shown = shown + 1
          local tag = is_circuit(st, circuit_name) and " [CIRCUIT]" or ""
          print(string.format("    slot %d: %s x%s dmg %s%s",
            slot, tostring(st.name), tostring(st.size), tostring(st.damage), tag))
          if is_circuit(st, circuit_name) then
            circuit_faces[#circuit_faces + 1] = { side = side, slot = slot, damage = st.damage }
          end
        end
      end
      if shown == 0 then
        print("    (empty — face has inventory handler but no items)")
      end
    end
  end

  print(string.format("  summary: %d face(s) with item inventory", faces_with_inv))
  if #circuit_faces > 0 then
    for _, c in ipairs(circuit_faces) do
      print(string.format("  >> circuit on side %d slot %d (damage %s) — item_bus_side should be %d",
        c.side, c.slot, tostring(c.damage), c.side))
    end
  else
    print("  >> no circuit on transposer right now (run a recipe first, or wrong bus wiring)")
  end
  if faces_with_inv < 2 then
    print("  >> WARN: need >= 2 faces with item slots (bus + ME import). ME may not touch transposer.")
  elseif faces_with_inv >= 2 and #circuit_faces > 0 then
    local bus = machine.item_bus_side
    local recover_hint = nil
    for side = 0, 5 do
      if side ~= bus then
        local ok_sz, sz = pcall(tp.getInventorySize, side)
        if ok_sz and sz and sz > 0 then recover_hint = side; break end
      end
    end
    if recover_hint and recover_hint ~= machine.recover_side then
      print(string.format("  >> recover_side candidate: %d (config has %s)",
        recover_hint, tostring(machine.recover_side)))
    end
  end
end

local only = LANE_ID
local from_vararg = ...
if from_vararg and from_vararg ~= "" then only = from_vararg end
if arg and arg[1] and arg[1] ~= "" then only = arg[1] end

print("[AutoOS] Transposer probe — sides 0=bottom 1=top 2=back 3=front 4=right 5=left")
for _, m in ipairs(Config.machines) do
  if not only or m.id == only then
    print_lane(m)
  end
end
print(string.rep("-", 56))
print("[AutoOS] Done. Set item_bus_side to the face with [CIRCUIT]; recover_side to another face with slots.")
