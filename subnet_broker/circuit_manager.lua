--[[
  AutoOS — Circuit Manager (1:1:1 lane topology)

  Push and recover programmed integrated circuits per lane:
    ME Interface setInterfaceConfiguration → transposer transferItem → clear interface.

  Circuits are stocked from subnet ME storage (database descriptor), not a vault chest.

  References: references/OC-GTNH-docs-main/docs/components/me_interface.lua
]]

local DescriptorCache = require("descriptor_cache")
local LaneSides = require("lane_sides")

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
  self.descriptors = deps.descriptor_cache or DescriptorCache.new({
    config = self.config,
    component = self.component,
  })
  return self
end

function CircuitManager:_proxy(address, hint)
  if self.proxies[address] then return self.proxies[address] end
  local ok, proxy = pcall(self.component.proxy, address, hint)
  if not ok then
    return nil, proxy
  end
  if proxy then
    self.proxies[address] = proxy
    return proxy
  end
  ok, proxy = pcall(self.component.proxy, address)
  if not ok then
    return nil, proxy
  end
  if proxy then
    self.proxies[address] = proxy
    return proxy
  end
  return nil, "proxy returned nil"
end

function CircuitManager:_on_network(address)
  local list = self.component.list and self.component.list() or {}
  return list[address] ~= nil
end

function CircuitManager:_check_address(label, address, hint)
  if not self:_on_network(address) then
    return false, string.format(
      "%s address %q not on OC network (run component.list())",
      label,
      tostring(address)
    )
  end
  local p, err = self:_proxy(address, hint)
  if not p then
    return false, string.format("%s proxy failed at %q: %s", label, tostring(address), tostring(err))
  end
  return true, p
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

  if not self:_on_network(db_addr) then
    return false, string.format(
      "database address %q not on OC network — set Config.database_address to your real database UUID",
      tostring(db_addr)
    )
  end

  local ok_if, iface_or_err = self:_check_address("me_interface", machine.interface_address, "me_interface")
  if not ok_if then
    return false, iface_or_err
  end
  local iface = iface_or_err
  if not iface.setInterfaceConfiguration then
    return false, "me_interface missing setInterfaceConfiguration"
  end

  local ok_tp, tp_or_err = self:_check_address("transposer", machine.transposer_address, "transposer")
  if not ok_tp then
    return false, tp_or_err
  end
  local tp = tp_or_err
  if not tp.transferItem then
    return false, "transposer missing transferItem"
  end

  local ok_desc, db_slot = self.descriptors:ensure_circuit(iface, circuit_damage)
  if not ok_desc then
    return false, tostring(db_slot)
  end

  local item_slot = machine.interface_item_slot or 1
  -- OC transposer slots are 1-based; config 0 means "first machine input slot".
  local input_slot = machine.input_slot
  if input_slot == nil or input_slot < 1 then input_slot = 1 end

  local ok_cfg, cfg_err = pcall(iface.setInterfaceConfiguration, item_slot, db_addr, db_slot, 1)
  if not ok_cfg then
    return false, "setInterfaceConfiguration error: " .. tostring(cfg_err)
  end
  if cfg_err == false then
    return false, "setInterfaceConfiguration returned false (check database slot " .. tostring(db_slot) .. ")"
  end

  local bus_side = LaneSides.item_bus_side(machine)
  if bus_side == nil then
    return false, "item_bus_side not configured"
  end
  -- Interface + input bus share one transposer face: transfer within that side.
  local from_slot = 1
  local moved = tp.transferItem(bus_side, bus_side, 1, from_slot, input_slot)
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

  local ok_tp, tp_or_err = self:_check_address("transposer", machine.transposer_address, "transposer")
  if not ok_tp then
    return false, tp_or_err
  end
  local tp = tp_or_err

  local bus_side = LaneSides.item_bus_side(machine)
  if bus_side == nil then
    return false, "item_bus_side not configured"
  end

  local bus_slot = self:_find_circuit_on_side(tp, bus_side, circuit_damage)
  if not bus_slot then
    return false, "no circuit found on machine input side for recovery"
  end

  local moved = tp.transferItem(bus_side, bus_side, 1, bus_slot, 1)
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
