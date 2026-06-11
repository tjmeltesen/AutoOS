--[[
  AutoOS — Circuit Manager (Phase 2)

  Push and recover programmed integrated circuits via ME Export Bus or Transposer.

  References: references/OC-GTNH-docs-main/docs/components/me_exportbus.lua
]]

local CircuitManager = {}
CircuitManager.__index = CircuitManager

local CIRCUIT_ITEM = "gregtech:gt.integrated_circuit"

local function vault_address(config)
  if config.circuit_vault and config.circuit_vault.address then
    return config.circuit_vault.address
  end
  return config.circuit_vault_address
end

local function find_machine(config, machine_id)
  for _, m in ipairs(config.machines) do
    if m.id == machine_id then
      return m
    end
  end
  return nil
end

function CircuitManager.new(deps)
  deps = deps or {}
  local self = setmetatable({}, CircuitManager)
  self.config = deps.config or error("CircuitManager.new: config required")
  self.component = deps.component or error("CircuitManager.new: component required")
  self.component_types = deps.component_types or {}

  if not next(self.component_types) and self.component.list then
    for addr, ctype in self.component.list() do
      self.component_types[addr] = ctype
    end
  end

  self.circuit_item = self.config.circuit_item_name or CIRCUIT_ITEM
  self.proxies = {}

  return self
end

function CircuitManager:_proxy(address, expected_type)
  if self.proxies[address] then
    return self.proxies[address]
  end
  local ok, proxy = pcall(self.component.proxy, address, expected_type)
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

function CircuitManager:resolve_route(machine_row)
  local route = machine_row.circuit_route or "auto"
  if route ~= "auto" then
    return route
  end

  local ctype = self.component_types[machine_row.bus_in]
  if ctype == "me_exportbus" then
    return "export_bus"
  end
  if ctype == "transposer" then
    return "transposer"
  end

  local proxy = self:_proxy(machine_row.bus_in)
  if proxy then
    if proxy.exportIntoSlot then
      return "export_bus"
    end
    if proxy.transferItem then
      return "transposer"
    end
  end

  return nil, "cannot resolve circuit_route for bus_in " .. tostring(machine_row.bus_in)
end

function CircuitManager:transposer_for(machine_row)
  local addr = machine_row.transposer_address or vault_address(self.config)
  if not addr then
    return nil, "no transposer_address or circuit_vault.address"
  end
  local tp = self:_proxy(addr, "transposer")
  if not tp or not tp.transferItem then
    return nil, "transposer not available at " .. tostring(addr)
  end
  return tp
end

function CircuitManager:db_slot_for(circuit_damage)
  local slots = self.config.circuit_db_slots
  if slots and slots[circuit_damage] then
    return slots[circuit_damage]
  end
  return nil, "no circuit_db_slots entry for damage " .. tostring(circuit_damage)
end

function CircuitManager:_stack_matches_circuit(stack, circuit_damage)
  if type(stack) ~= "table" then
    return false
  end
  local name = stack.name or ""
  if name ~= self.circuit_item and not name:find("integrated_circuit", 1, true) then
    return false
  end
  return stack.damage == circuit_damage
end

function CircuitManager:_find_circuit_slot(tp, vault_side, circuit_damage)
  local size = tp.getInventorySize and tp.getInventorySize(vault_side) or 0
  for slot = 1, size do
    local stack = tp.getStackInSlot and tp.getStackInSlot(vault_side, slot)
    if self:_stack_matches_circuit(stack, circuit_damage) then
      return slot
    end
  end
  return nil
end

function CircuitManager:_find_circuit_on_bus(tp, bus_side, circuit_damage)
  local size = tp.getInventorySize and tp.getInventorySize(bus_side) or 0
  for slot = 1, size do
    local stack = tp.getStackInSlot and tp.getStackInSlot(bus_side, slot)
    if self:_stack_matches_circuit(stack, circuit_damage) then
      return slot
    end
  end
  return nil
end

function CircuitManager:push_circuit(machine_id, circuit_damage)
  local machine = find_machine(self.config, machine_id)
  if not machine then
    return false, "unknown machine_id " .. tostring(machine_id)
  end

  local route, route_err = self:resolve_route(machine)
  if not route then
    return false, route_err
  end

  if route == "export_bus" then
    return self:_push_export_bus(machine, circuit_damage)
  end

  return self:_push_transposer(machine, circuit_damage)
end

function CircuitManager:_push_export_bus(machine, circuit_damage)
  if machine.bus_export_side == nil then
    return false, "bus_export_side required for export_bus path"
  end

  local db_addr = self.config.database_address
  if not db_addr or db_addr == "" then
    return false, "database_address required for export_bus path"
  end

  local db_slot, slot_err = self:db_slot_for(circuit_damage)
  if not db_slot then
    return false, slot_err
  end

  local bus = self:_proxy(machine.bus_in, "me_exportbus")
  if not bus or not bus.setExportConfiguration then
    return false, "me_exportbus not available at " .. tostring(machine.bus_in)
  end

  local side = machine.bus_export_side
  local ok = bus.setExportConfiguration(side, db_addr, db_slot)
  if not ok then
    return false, "setExportConfiguration failed"
  end

  if bus.exportIntoSlot then
    local gt_slot = machine.gt_bus_slot or 0
    ok = bus.exportIntoSlot(side, gt_slot)
    if not ok then
      return false, "exportIntoSlot failed"
    end
  end

  return true
end

function CircuitManager:_push_transposer(machine, circuit_damage)
  local tp, tp_err = self:transposer_for(machine)
  if not tp then
    return false, tp_err
  end

  local vault_side = machine.transposer_vault_side
  local bus_side = machine.transposer_to_bus_side
  if vault_side == nil or bus_side == nil then
    return false, "transposer_vault_side and transposer_to_bus_side required"
  end

  local slot = self:_find_circuit_slot(tp, vault_side, circuit_damage)
  if not slot then
    return false, "circuit damage " .. tostring(circuit_damage) .. " not found in vault"
  end

  local moved = tp.transferItem(vault_side, bus_side, 1, slot, machine.gt_bus_slot or 0)
  if not moved or moved < 1 then
    return false, "transferItem vault→bus failed"
  end

  return true
end

function CircuitManager:recover_circuit(machine_id, circuit_damage)
  local machine = find_machine(self.config, machine_id)
  if not machine then
    return false, "unknown machine_id " .. tostring(machine_id)
  end

  local route = machine.circuit_route or "auto"
  local resolved = route
  if route == "auto" then
    resolved = self:resolve_route(machine)
  end

  local tp, tp_err = self:transposer_for(machine)
  if not tp then
    if resolved == "export_bus" then
      return false, "export-only push path; configure transposer_address for recovery"
    end
    return false, tp_err
  end

  local vault_side = machine.transposer_vault_side
  local bus_side = machine.transposer_to_bus_side
  if vault_side == nil or bus_side == nil then
    return false, "transposer_vault_side and transposer_to_bus_side required for recovery"
  end

  local bus_slot
  if circuit_damage then
    bus_slot = self:_find_circuit_on_bus(tp, bus_side, circuit_damage)
  else
    local size = tp.getInventorySize and tp.getInventorySize(bus_side) or 0
    for slot = 1, size do
      local stack = tp.getStackInSlot and tp.getStackInSlot(bus_side, slot)
      if type(stack) == "table" and (stack.name or ""):find("integrated_circuit", 1, true) then
        bus_slot = slot
        break
      end
    end
  end

  if not bus_slot then
    return false, "no circuit found on bus side for recovery"
  end

  local vault_slot = self:_find_empty_vault_slot(tp, vault_side) or 1
  local moved = tp.transferItem(bus_side, vault_side, 1, bus_slot, vault_slot)
  if not moved or moved < 1 then
    return false, "transferItem bus→vault failed"
  end

  return true
end

function CircuitManager:_find_empty_vault_slot(tp, vault_side)
  local size = tp.getInventorySize and tp.getInventorySize(vault_side) or 0
  for slot = 1, size do
    local stack = tp.getStackInSlot and tp.getStackInSlot(vault_side, slot)
    if stack == nil or (type(stack) == "table" and (stack.size or 0) == 0) then
      return slot
    end
  end
  return nil
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
