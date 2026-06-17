--[[
  AutoOS — Recover transfer diagnostic (tries transferItem variants; may move 1 circuit)

  Run with a circuit on the input bus:
    loadfile("/home/subnet_broker/test_recover_transfer.lua")("machine_01")

  Prints raw transferItem results for each strategy. If one succeeds, the circuit moves.
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("config")
local component = require("component")

local lane_id = ...
if (not lane_id or lane_id == "") and arg and arg[1] then lane_id = arg[1] end
lane_id = lane_id or "machine_01"

local machine
for _, m in ipairs(Config.machines) do
  if m.id == lane_id then machine = m; break end
end
if not machine then
  print("unknown lane " .. tostring(lane_id))
  return
end

local CIRCUIT = Config.circuit_item_name or "gregtech:gt.integrated_circuit"
local function is_circuit(stack)
  if type(stack) ~= "table" then return false end
  local n = stack.name or ""
  return n == CIRCUIT or n:find("integrated_circuit", 1, true) ~= nil
end

local LaneSides = require("lane_sides")
local tp_addr = LaneSides.item_transposer_address(machine)
local tp = component.proxy(tp_addr, "transposer") or component.proxy(tp_addr)
if not tp or not tp.transferItem then
  print("transposer proxy failed")
  return
end

local bus = machine.item_bus_side
local recover = machine.recover_side
local bus_slot, bus_stack

for slot = 1, (tp.getInventorySize(bus) or 0) do
  local st = tp.getStackInSlot(bus, slot)
  if is_circuit(st) then bus_slot, bus_stack = slot, st; break end
end

print(string.format("[Transfer test] %s  bus side %d -> recover side %d", lane_id, bus, recover))
if not bus_slot then
  print("NO circuit on item_bus_side — run a recipe first")
  return
end
print(string.format("  source: side %d slot %d  %s dmg %s", bus, bus_slot, bus_stack.name, tostring(bus_stack.damage)))

local rsize = tp.getInventorySize(recover) or 0
print(string.format("  recover face: %d slots", rsize))
for slot = 1, math.min(rsize, 9) do
  local st = tp.getStackInSlot(recover, slot)
  if st and (st.size or 0) > 0 then
    print(string.format("    slot %d OCCUPIED: %s x%s", slot, st.name, tostring(st.size)))
  end
end

local function try_call(label, fn)
  local ok, r1, r2 = pcall(fn)
  if not ok then
    print(string.format("  FAIL %-14s pcall error: %s", label, tostring(r1)))
    return false
  end
  local moved = type(r1) == "number" and r1 or (r1 == true and type(r2) == "number" and r2 or 0)
  local err = (r1 == false and type(r2) == "string") and r2 or nil
  print(string.format("  %-14s -> %s %s", label, tostring(r1), tostring(r2)))
  if moved >= 1 then
    print("  ** TRANSFER OK — circuit should have moved **")
    return true
  end
  if err then print("       reason: " .. err) end
  return false
end

local tests = {
  { string.format("slot %d->%d", bus_slot, machine.recover_slot or 1), function()
    return tp.transferItem(bus, recover, 1, bus_slot, machine.recover_slot or 1)
  end },
  { "slot->1", function() return tp.transferItem(bus, recover, 1, bus_slot, 1) end },
  { "auto dest", function() return tp.transferItem(bus, recover, 1, bus_slot) end },
  { "auto slots", function() return tp.transferItem(bus, recover, 1) end },
}
for slot = 2, rsize do
  tests[#tests + 1] = { "slot->" .. slot, function()
    return tp.transferItem(bus, recover, 1, bus_slot, slot)
  end }
end

print("Trying transferItem variants:")
for _, t in ipairs(tests) do
  if try_call(t[1], t[2]) then break end
end

print("Bus after:")
for slot = 1, (tp.getInventorySize(bus) or 0) do
  local st = tp.getStackInSlot(bus, slot)
  if st then print(string.format("  bus slot %d: %s", slot, st.name)) end
end
