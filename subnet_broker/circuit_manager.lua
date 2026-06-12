--[[
  AutoOS — Circuit Manager (1:1:1 lane topology)

  Push and recover programmed integrated circuits per lane:
    ME Interface setInterfaceConfiguration → transposer transferItem → clear interface.

  Circuits are stocked from subnet ME storage (database descriptor), not a vault chest.

  References: references/OC-GTNH-docs-main/docs/components/me_interface.lua
]]

local CircuitManager = {}
CircuitManager.__index = CircuitManager

local CIRCUIT_ITEM = "gregtech:gt.integrated_circuit"

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
  self.circuit_item = self.config.circuit_item_name or CIRCUIT_ITEM
  self.proxies = {}
  return self
end

function CircuitManager:_proxy(address, hint)
  if self.proxies[address] then return self.proxies[address] end
  local ok, proxy = pcall(self.component.proxy, address, hint)
  if ok and proxy then
    self.proxies[address] = proxy
    return proxy
  end
  ok, proxy = pcall(self.component.proxy, address)
  if ok and proxy then
    self.proxies[address] = proxy
    return proxy
  end
  return nil
end

function CircuitManager:db_slot_for(circuit_damage)
  local slots = self.config.circuit_db_slots
  if slots and slots[circuit_damage] then
    return slots[circuit_damage]
  end
  return nil, "no circuit_db_slots entry for damage " .. tostring(circuit_damage)
end

function CircuitManager:_stack_matches_circuit(stack, circuit_damage)
  if type(stack) ~= "table" then return false end
  local name = stack.name or ""
  if name ~= self.circuit_item and not name:find("integrated_circuit", 1, true) then
    return false
  end
  if circuit_damage == nil then return true end
  return stack.damage == circuit_damage
end

function CircuitManager:_find_circuit_on_side(tp, side, circuit_damage)
  local size = tp.getInventorySize and tp.getInventorySize(side) or 0
  for slot = 1, size do
    local stack = tp.getStackInSlot and tp.getStackInSlot(side, slot)
    if self:_stack_matches_circuit(stack, circuit_damage) then
      return slot
    end
  end
  return nil
end

--- Stock circuit from subnet via lane ME interface, transposer to machine input, clear interface.
---@return boolean ok
---@return string|nil err
function CircuitManager:push_circuit(machine_id, circuit_damage)
  local machine = find_machine(self.config, machine_id)
  if not machine then
    return false, "unknown machine_id " .. tostring(machine_id)
  end

  local db_addr = self.config.database_address
  if not db_addr or db_addr == "" then
    return false, "database_address required"
  end

  local db_slot, slot_err = self:db_slot_for(circuit_damage)
  if not db_slot then
    return false, slot_err
  end

  local iface = self:_proxy(machine.interface_address, "me_interface")
  if not iface or not iface.setInterfaceConfiguration then
    return false, "me_interface not available at " .. tostring(machine.interface_address)
  end

  local tp = self:_proxy(machine.transposer_address, "transposer")
  if not tp or not tp.transferItem then
    return false, "transposer not available at " .. tostring(machine.transposer_address)
  end

  local item_slot = machine.interface_item_slot or 1
  -- OC transposer slots are 1-based; config 0 means "first machine input slot".
  local input_slot = machine.input_slot
  if input_slot == nil or input_slot < 1 then input_slot = 1 end

  local ok_cfg = iface.setInterfaceConfiguration(item_slot, db_addr, db_slot, 1)
  if not ok_cfg then
    return false, "setInterfaceConfiguration failed"
  end

  -- pull_side / push_side are the item input bus faces (not the fluid hatch).
  local moved = tp.transferItem(machine.pull_side, machine.push_side, 1, nil, input_slot)
  if not moved or moved < 1 then
    iface.setInterfaceConfiguration(item_slot)
    return false, "transferItem interface→machine failed"
  end

  iface.setInterfaceConfiguration(item_slot)
  return true
end

--- Recover non-consumable circuit from machine input back to interface side (subnet storage).
---@return boolean ok
---@return string|nil err
function CircuitManager:recover_circuit(machine_id, circuit_damage)
  local machine = find_machine(self.config, machine_id)
  if not machine then
    return false, "unknown machine_id " .. tostring(machine_id)
  end

  local tp = self:_proxy(machine.transposer_address, "transposer")
  if not tp or not tp.transferItem then
    return false, "transposer not available at " .. tostring(machine.transposer_address)
  end

  local bus_slot = self:_find_circuit_on_side(tp, machine.push_side, circuit_damage)
  if not bus_slot then
    return false, "no circuit found on machine input side for recovery"
  end

  local moved = tp.transferItem(machine.push_side, machine.pull_side, 1, bus_slot, 1)
  if not moved or moved < 1 then
    return false, "transferItem machine→interface failed"
  end

  return true
end

function CircuitManager:recover_all(machine_ids)
  local summary = {}
  for _, id in ipairs(machine_ids) do
    local ok, err = self:recover_circuit(id)
    summary[id] = { ok = ok, err = err }
  end
  return summary
end

return CircuitManager
