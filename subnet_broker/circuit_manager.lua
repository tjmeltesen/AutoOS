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

--- Public helper for other modules (e.g. circuit_loop).
function CircuitManager:stack_is_circuit(stack, circuit_damage)
  return self:_stack_is_circuit(stack, circuit_damage)
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

--- Public helper: safe to call from other modules.
---@return integer|nil slot
---@return table|nil stack
function CircuitManager:find_circuit_slot(tp, side, circuit_damage)
  return self:_find_circuit_on_side(tp, side, circuit_damage)
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

function CircuitManager:_transfer_result(r1, r2)
  if type(r1) == "number" then
    return r1, nil
  end
  if r1 == true and type(r2) == "number" then
    return r2, nil
  end
  if r1 == false then
    return 0, type(r2) == "string" and r2 or tostring(r2)
  end
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

--- Public helper: summarize inventory state on one face.
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
  add("auto-slots", function()
    return tp.transferItem(from_side, to_side, 1)
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

--- Public helper: transfer one item with retry strategy.
---@return integer moved
---@return string|nil err
function CircuitManager:transfer_one(tp, from_side, to_side, from_slot, to_slot)
  return self:_transfer_with_retries(tp, from_side, to_side, from_slot, to_slot)
end

--- Scan every transposer face for integrated circuits (REPL / diag).
---@param machine_id string
---@return table[] hits { side, slot, name, damage, size }
function CircuitManager:scan_transposer(machine_id)
  local machine = find_machine(self.config, machine_id)
  if not machine then return nil, "unknown machine_id " .. tostring(machine_id) end

  local tp, tp_err = HW.require_proxy(self.component, "transposer", machine.transposer_address, "transposer")
  if not tp then return nil, tp_err end

  local hits = {}
  for side = 0, 5 do
    local size = tp.getInventorySize and tp.getInventorySize(side) or 0
    for slot = 1, size do
      local stack = tp.getStackInSlot and tp.getStackInSlot(side, slot)
      if self:_stack_is_circuit(stack, nil) then
        hits[#hits + 1] = {
          side = side,
          slot = slot,
          name = stack.name,
          damage = stack.damage,
          size = stack.size,
        }
      end
    end
  end
  return hits
end

function CircuitManager:_circuit_location_hint(tp, bus_side, circuit_damage)
  for side = 0, 5 do
    if side ~= bus_side then
      local slot = self:_find_circuit_on_side(tp, side, circuit_damage)
      if not slot and circuit_damage then
        slot = self:_find_circuit_on_side(tp, side, nil)
      end
      if slot then
        return string.format(
          "circuit on transposer side %d slot %d but item_bus_side is %d — fix config",
          side, slot, bus_side
        )
      end
    end
  end
  return nil
end

function CircuitManager:_resolve_recover_interface_address(machine)
  local mode = self.config.interface_mode or "transposer"
  if mode == "transposer" then
    return nil
  end
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

  local moved, xfer_err = self:_transfer_with_retries(tp, iface_side, bus_side, from_slot, input_slot)
  iface.setInterfaceConfiguration(item_slot)
  if moved < 1 then
    return false, string.format(
      "transferItem interface→bus failed (sides %d→%d)%s",
      iface_side, bus_side, xfer_err and (": " .. xfer_err) or ""
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

  local tp, tp_err = HW.require_proxy(self.component, "transposer", machine.transposer_address, "transposer")
  if not tp then return false, tp_err end

  local recover_side = LaneSides.recover_side(machine)
  local bus_side = LaneSides.item_bus_side(machine)
  local recover_slot = LaneSides.recover_slot(machine)

  local bus_slot = self:_find_circuit_on_side(tp, bus_side, circuit_damage)
  if not bus_slot and circuit_damage then
    bus_slot = self:_find_circuit_on_side(tp, bus_side, nil)
  end
  if not bus_slot then
    local hint = self:_circuit_location_hint(tp, bus_side, circuit_damage)
    if hint then return false, hint end
    return true, "no circuit on item_bus_side (nothing to recover)"
  end

  local moved, xfer_err = self:_transfer_with_retries(tp, bus_side, recover_side, bus_slot, recover_slot)
  if moved < 1 then
    local hint = " — clear ME import interface config; ensure recover face slots are empty"
    return false, string.format(
      "transferItem bus→recover failed (sides %d→%d slot %d→%d)%s\n  bus: %s\n  recover: %s%s",
      bus_side, recover_side, bus_slot, recover_slot,
      xfer_err and (": " .. xfer_err) or "",
      self:_describe_face(tp, bus_side),
      self:_describe_face(tp, recover_side),
      hint
    )
  end

  -- Optional: OC me_interface clear when an adapter is wired (export/stocking mode).
  -- Array Watch default is transposer-only — ME absorbs via the physical interface face.
  local iface_addr = self:_resolve_recover_interface_address(machine)
  if iface_addr and iface_addr ~= "" and self.config.recover_clear_interface ~= false then
    local iface = HW.require_proxy(self.component, "me_interface", iface_addr, "me_interface")
    if iface and iface.setInterfaceConfiguration then
      pcall(iface.setInterfaceConfiguration, recover_slot)
    end
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
