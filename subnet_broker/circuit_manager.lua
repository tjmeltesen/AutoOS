--[[
  AutoOS — Transposer helpers for lane dispatch

  find/transfer/scan integrated circuits via transposer faces.
]]

local HW = require("hw")
local LaneSides = require("lane_sides")

local CircuitManager = {}
CircuitManager.__index = CircuitManager

local TRANSFER_ATTEMPTS = 4

local function find_machine(config, machine_id)
  for _, m in ipairs(config.machines) do
    if m.id == machine_id then return m end
  end
  return nil
end

function CircuitManager.new(deps)
  deps = deps or {}
  local self = setmetatable({}, CircuitManager)
  self.config = deps.config or error("CircuitManager.new: config required")
  self.component = deps.component or error("CircuitManager.new: component required")
  self.descriptor_cache = deps.descriptor_cache
  self.circuit_item = self.config.circuit_item_name or "gregtech:gt.integrated_circuit"
  return self
end

function CircuitManager:_stack_is_circuit(stack, circuit_damage)
  if type(stack) ~= "table" then return false end
  local name = stack.name or ""
  if name ~= self.circuit_item and not name:find("integrated_circuit", 1, true) then
    return false
  end
  if circuit_damage == nil then return true end
  return stack.damage == circuit_damage
end

function CircuitManager:stack_is_circuit(stack, circuit_damage)
  return self:_stack_is_circuit(stack, circuit_damage)
end

function CircuitManager:_find_circuit_on_side(tp, side, circuit_damage)
  local size = tp.getInventorySize and tp.getInventorySize(side) or 0
  for slot = 1, size do
    local stack = tp.getStackInSlot and tp.getStackInSlot(side, slot)
    if self:_stack_is_circuit(stack, circuit_damage) then
      return slot, stack
    end
  end
  return nil
end

function CircuitManager:find_circuit_slot(tp, side, circuit_damage)
  return self:_find_circuit_on_side(tp, side, circuit_damage)
end

function CircuitManager:_transfer_result(r1, r2)
  if type(r1) == "number" then return r1, nil end
  if r1 == true and type(r2) == "number" then return r2, nil end
  if r1 == false then return 0, type(r2) == "string" and r2 or tostring(r2) end
  return 0, nil
end

function CircuitManager:_describe_face(tp, side)
  local size = tp.getInventorySize and tp.getInventorySize(side) or 0
  if not size or size < 1 then
    return string.format("side %d (no item slots)", side)
  end
  local parts = {}
  for slot = 1, math.min(size, 9) do
    local st = tp.getStackInSlot and tp.getStackInSlot(side, slot)
    if st and (st.size or 0) > 0 then
      parts[#parts + 1] = string.format("slot%d=%s", slot, tostring(st.name))
    end
  end
  if #parts == 0 then
    return string.format("side %d (%d slots, all empty)", side, size)
  end
  return string.format("side %d (%s)", side, table.concat(parts, ", "))
end

function CircuitManager:describe_face(tp, side)
  return self:_describe_face(tp, side)
end

function CircuitManager:_transfer_with_retries(tp, from_side, to_side, from_slot, to_slot)
  local strategies = {}
  local seen = {}

  local function add(label, fn)
    if not seen[label] then
      seen[label] = true
      strategies[#strategies + 1] = { label = label, fn = fn }
    end
  end

  local dest_size = 1
  if tp.getInventorySize then
    local ok, n = pcall(tp.getInventorySize, to_side)
    if ok and type(n) == "number" and n > 0 then dest_size = n end
  end

  if to_slot then add("to=" .. to_slot, function()
    return tp.transferItem(from_side, to_side, 1, from_slot, to_slot)
  end) end
  add("to=1", function()
    return tp.transferItem(from_side, to_side, 1, from_slot, 1)
  end)
  for dest = 2, dest_size do
    add("to=" .. dest, function()
      return tp.transferItem(from_side, to_side, 1, from_slot, dest)
    end)
  end
  add("auto-to", function()
    return tp.transferItem(from_side, to_side, 1, from_slot)
  end)

  local last_err = nil
  for attempt = 1, TRANSFER_ATTEMPTS do
    for _, strat in ipairs(strategies) do
      local ok_call, r1, r2 = pcall(strat.fn)
      if not ok_call then
        last_err = tostring(r1)
      else
        local moved, err = self:_transfer_result(r1, r2)
        if err and err ~= "" then last_err = err end
        if moved >= 1 then return moved, nil end
      end
    end
    if attempt < TRANSFER_ATTEMPTS then HW.sleep(0.25) end
  end
  return 0, last_err
end

function CircuitManager:transfer_one(tp, from_side, to_side, from_slot, to_slot)
  return self:_transfer_with_retries(tp, from_side, to_side, from_slot, to_slot)
end

function CircuitManager:scan_transposer(machine_id, which)
  local machine = find_machine(self.config, machine_id)
  if not machine then return nil, "unknown machine_id " .. tostring(machine_id) end

  local addr = which == "fluid"
    and LaneSides.fluid_transposer_address(machine)
    or LaneSides.item_transposer_address(machine)
  local tp, tp_err = HW.require_proxy(self.component, "transposer", addr, "transposer")
  if not tp then return nil, tp_err end

  local hits = {}
  for side = 0, 5 do
    local size = tp.getInventorySize and tp.getInventorySize(side) or 0
    for slot = 1, size do
      local stack = tp.getStackInSlot and tp.getStackInSlot(side, slot)
      if self:_stack_is_circuit(stack, nil) then
        hits[#hits + 1] = {
          side = side, slot = slot,
          name = stack.name, damage = stack.damage, size = stack.size,
        }
      end
    end
  end
  return hits
end

return CircuitManager
