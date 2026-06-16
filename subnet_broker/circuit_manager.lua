--[[
  AutoOS — Circuit Manager (Array Watch topology + legacy dispatch)

  Push and recover programmed integrated circuits per lane:
    ME interface item stocking → transposer transferItem → clear interface.

  Production path is recover-only (Array Watch): recover after machine finishes.
  push_circuit is kept for legacy/demoted dispatch tooling.

  References: references/OC-GTNH-docs-main/docs/components/me_interface.lua
]]

local DescriptorCache = require("descriptor_cache")
local HW = require("hw")
local LaneSides = require("lane_sides")

local CircuitManager = {}
CircuitManager.__index = CircuitManager

local STOCK_WAIT_ATTEMPTS = 8
local STOCK_WAIT_SLEEP = 0.25
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
  self.circuit_item = self.config.circuit_item_name or "gregtech:gt.integrated_circuit"
  self.descriptors = deps.descriptor_cache or DescriptorCache.new({
    config = self.config,
    component = self.component,
  })
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

--- First slot on `side` holding a matching circuit (nil = none).
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

--- Wait for AE2 to stock the interface buffer after setInterfaceConfiguration.
function CircuitManager:_wait_interface_stock(tp, side, slot)
  for _ = 1, STOCK_WAIT_ATTEMPTS do
    local stack = tp.getStackInSlot and tp.getStackInSlot(side, slot)
    if stack and (stack.size or 0) >= 1 then
      return true
    end
    HW.sleep(STOCK_WAIT_SLEEP)
  end
  return false
end

function CircuitManager:_transfer_with_retries(tp, from_side, to_side, from_slot, to_slot)
  for i = 1, TRANSFER_ATTEMPTS do
    local moved = tp.transferItem(from_side, to_side, 1, from_slot, to_slot)
    if moved and moved >= 1 then
      return moved
    end
    if i < TRANSFER_ATTEMPTS then HW.sleep(0.25) end
  end
  return 0
end

function CircuitManager:_resolve_recover_interface_address(machine)
  local mode = self.config.interface_mode or "per_lane"
  if mode == "shared" then
    return self.config.shared_interface_address
  end
  return machine.interface_address
end

--- Stock a circuit from subnet ME and move it onto the machine input bus.
---@param machine_id string
---@param circuit_damage integer
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
  if not HW.on_network(self.component, db_addr) then
    return false, string.format(
      "database address %q not on OC network — set Config.database_address to your real database UUID",
      tostring(db_addr)
    )
  end

  if not machine.interface_address or machine.interface_address == "" then
    return false, "push_circuit requires machines[].interface_address"
  end
  local iface, if_err = HW.require_proxy(self.component, "me_interface", machine.interface_address, "me_interface")
  if not iface then return false, if_err end
  if not iface.setInterfaceConfiguration then
    return false, "me_interface missing setInterfaceConfiguration"
  end

  local tp, tp_err = HW.require_proxy(self.component, "transposer", machine.transposer_address, "transposer")
  if not tp then return false, tp_err end
  if not tp.transferItem then
    return false, "transposer missing transferItem"
  end

  local iface_side = LaneSides.interface_item_side(machine)
  local bus_side = LaneSides.item_bus_side(machine)

  -- Idempotent: correct circuit already on the bus → done.
  if self:_find_circuit_on_side(tp, bus_side, circuit_damage) then
    return true
  end
  -- A different circuit on the bus would corrupt the recipe.
  local other_slot, other = self:_find_circuit_on_side(tp, bus_side, nil)
  if other_slot and other and other.damage ~= circuit_damage then
    return false, string.format(
      "input bus has circuit %s but recipe needs %s — recover or clear the bus first",
      tostring(other.damage), tostring(circuit_damage)
    )
  end

  local ok_desc, db_slot = self.descriptors:ensure_circuit(iface, circuit_damage)
  if not ok_desc then
    return false, tostring(db_slot)
  end

  local item_slot = machine.interface_item_slot or 1
  local input_slot = machine.input_slot or 1
  if input_slot < 1 then input_slot = 1 end

  local ok_cfg, cfg_err = pcall(iface.setInterfaceConfiguration, item_slot, db_addr, db_slot, 1)
  if not ok_cfg then
    return false, "setInterfaceConfiguration error: " .. tostring(cfg_err)
  end
  if cfg_err == false then
    return false, "setInterfaceConfiguration returned false (check database slot " .. tostring(db_slot) .. ")"
  end

  local from_slot = item_slot
  if not self:_wait_interface_stock(tp, iface_side, from_slot) then
    iface.setInterfaceConfiguration(item_slot)
    local hint = string.format(
      "interface face %d slot %d empty after stocking — is circuit %s in subnet ME?",
      iface_side, from_slot, tostring(circuit_damage)
    )
    if iface.getItemsInNetwork then
      local net = iface.getItemsInNetwork({ name = self.circuit_item, damage = circuit_damage })
      if not net or #net == 0 then
        hint = hint .. " (getItemsInNetwork found 0)"
      end
    end
    return false, hint
  end

  -- Reject a stale descriptor: the interface must hold the exact circuit asked for.
  local stocked = tp.getStackInSlot and tp.getStackInSlot(iface_side, from_slot)
  if not self:_stack_is_circuit(stocked, circuit_damage) then
    iface.setInterfaceConfiguration(item_slot)
    return false, string.format(
      "interface stocked circuit %s, expected %s — database slot stale or wrong circuit in subnet ME",
      tostring(stocked and stocked.damage), tostring(circuit_damage)
    )
  end

  local moved = self:_transfer_with_retries(tp, iface_side, bus_side, from_slot, input_slot)
  iface.setInterfaceConfiguration(item_slot)
  if moved < 1 then
    return false, string.format(
      "transferItem interface→bus failed (sides %d→%d) — check interface_item_side / item_bus_side",
      iface_side, bus_side
    )
  end

  -- Sanity check: the right circuit really landed on the bus.
  if not self:_find_circuit_on_side(tp, bus_side, circuit_damage) then
    return false, string.format(
      "circuit moved but damage %s not found on bus side %d after push",
      tostring(circuit_damage), bus_side
    )
  end

  return true
end

--- Recover a non-consumable circuit from the machine input bus back into subnet ME.
---@param machine_id string
---@param circuit_damage integer|nil nil recovers any circuit on the bus
---@return boolean ok
---@return string|nil err
function CircuitManager:recover_circuit(machine_id, circuit_damage)
  local machine = find_machine(self.config, machine_id)
  if not machine then
    return false, "unknown machine_id " .. tostring(machine_id)
  end

  local iface_addr = self:_resolve_recover_interface_address(machine)
  if not iface_addr or iface_addr == "" then
    return false, "recover interface address not configured (per_lane: interface_address, shared: shared_interface_address)"
  end

  local iface, if_err = HW.require_proxy(self.component, "me_interface", iface_addr, "me_interface")
  if not iface then return false, if_err end

  local tp, tp_err = HW.require_proxy(self.component, "transposer", machine.transposer_address, "transposer")
  if not tp then return false, tp_err end

  local iface_side = LaneSides.recover_side(machine)
  local bus_side = LaneSides.item_bus_side(machine)
  local iface_slot = LaneSides.recover_slot(machine)

  local bus_slot = self:_find_circuit_on_side(tp, bus_side, circuit_damage)
  if not bus_slot and circuit_damage then
    bus_slot = self:_find_circuit_on_side(tp, bus_side, nil)
  end
  if not bus_slot then
    return true
  end

  local moved = self:_transfer_with_retries(tp, bus_side, iface_side, bus_slot, iface_slot)
  if moved < 1 then
    return false, string.format(
      "transferItem bus→interface failed (sides %d→%d slot %d→%d)",
      bus_side, iface_side, bus_slot, iface_slot
    )
  end

  -- Return the circuit from the interface buffer to subnet ME (matches push clear).
  if self.config.recover_clear_interface ~= false and iface.setInterfaceConfiguration then
    pcall(iface.setInterfaceConfiguration, iface_slot)
  end
  HW.sleep(STOCK_WAIT_SLEEP)

  if self:_find_circuit_on_side(tp, bus_side, nil) then
    return false, string.format(
      "circuit still on bus side %d after recover — check item_bus_side / input_slot",
      bus_side
    )
  end

  return true
end

--- Recover circuits on several lanes; returns per-lane { ok, err }.
function CircuitManager:recover_all(machine_ids)
  local summary = {}
  for _, id in ipairs(machine_ids) do
    local ok, err = self:recover_circuit(id)
    summary[id] = { ok = ok, err = err }
  end
  return summary
end

return CircuitManager
