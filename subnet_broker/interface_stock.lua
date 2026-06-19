--[[
  AutoOS — Lane ME interface stocking helper

  Configures per-lane ME interface slots from descriptor cache, then releases
  interface configs + descriptor slots after transfer.
]]

local HW = require("hw")
local FluidTanks = require("fluid_tanks")

local InterfaceStock = {}
InterfaceStock.__index = InterfaceStock

local function stack_matches(st, spec)
  if type(st) ~= "table" then return false end
  if spec.name and st.name ~= spec.name then return false end
  if spec.damage ~= nil and st.damage ~= spec.damage then return false end
  if spec.label and st.label then
    return st.label:lower() == spec.label:lower()
  end
  return true
end

local function fluid_level(tp, side)
  return FluidTanks.tank_level(tp, side)
end

function InterfaceStock.new(deps)
  deps = deps or {}
  local self = setmetatable({}, InterfaceStock)
  self.config = deps.config or error("InterfaceStock.new: config required")
  self.component = deps.component or error("InterfaceStock.new: component required")
  self.descriptor_cache = deps.descriptor_cache or error("InterfaceStock.new: descriptor_cache required")
  self.sleep = deps.sleep or HW.sleep
  return self
end

function InterfaceStock:_item_slot_limit(machine)
  return machine.interface_item_slots
    or self.config.interface_item_slots
    or 9
end

function InterfaceStock:_item_slot_start(machine)
  return machine.interface_item_slot_start
    or self.config.interface_item_slot_start
    or 1
end

function InterfaceStock:_fluid_side(machine)
  return machine.interface_fluid_side
    or self.config.interface_fluid_side
    or 0
end

function InterfaceStock:_iface(machine)
  local addr = machine.interface_address
  if (not addr or addr == "")
    and self.config.shared_interface_address
    and self.config.shared_interface_address ~= "" then
    addr = self.config.shared_interface_address
  end
  local iface, err = HW.require_proxy(self.component, "me_interface", addr, "me_interface")
  if iface then return iface end
  return nil, string.format(
    "%s (machine=%s, machine.interface_address=%s, shared_interface_address=%s)",
    tostring(err),
    tostring(machine and machine.id or "?"),
    tostring(machine and machine.interface_address or ""),
    tostring(self.config.shared_interface_address or "")
  )
end

function InterfaceStock:_push_slot(active, slot)
  for _, s in ipairs(active.db_slots) do
    if s == slot then return end
  end
  active.db_slots[#active.db_slots + 1] = slot
end

function InterfaceStock:_new_active(machine, iface)
  return {
    machine = machine,
    iface = iface,
    items = {},
    fluids = {},
    db_slots = {},
  }
end

function InterfaceStock:stock_one_item(machine, spec, slot_index)
  spec = spec or {}
  local iface, if_err = self:_iface(machine)
  if not iface then return false, if_err end
  if not iface.setInterfaceConfiguration then
    return false, "me_interface missing setInterfaceConfiguration"
  end

  local slot_start = self:_item_slot_start(machine)
  local slot_limit = self:_item_slot_limit(machine)
  local idx = slot_index or 1
  if idx < 1 or idx > slot_limit then
    return false, string.format("item slot index %d out of range (1..%d)", idx, slot_limit)
  end
  local iface_slot = spec.iface_slot or (slot_start + idx - 1)
  local active = self:_new_active(machine, iface)
  local ok_slot, db_slot = self.descriptor_cache:ensure_item(iface, spec)
  if not ok_slot then return false, tostring(db_slot), active end
  local ok_cfg, cfg_err = pcall(
    iface.setInterfaceConfiguration,
    iface_slot,
    self.config.database_address,
    db_slot,
    spec.count or 1
  )
  if not ok_cfg or cfg_err == false then
    return false, "setInterfaceConfiguration failed: " .. tostring(cfg_err), active
  end
  active.items[1] = { iface_slot = iface_slot, db_slot = db_slot, spec = spec }
  self:_push_slot(active, db_slot)
  return true, nil, active
end

function InterfaceStock:stock_one_fluid(machine, spec)
  spec = spec or {}
  local iface, if_err = self:_iface(machine)
  if not iface then return false, if_err end
  if not iface.setFluidInterfaceConfiguration then
    return false, "me_interface missing setFluidInterfaceConfiguration"
  end
  local active = self:_new_active(machine, iface)
  local ok_slot, db_slot = self.descriptor_cache:ensure_fluid(iface, spec)
  if not ok_slot then return false, tostring(db_slot), active end
  local side = self:_fluid_side(machine)
  local ok_cfg, cfg_err = pcall(
    iface.setFluidInterfaceConfiguration,
    side,
    self.config.database_address,
    db_slot
  )
  if not ok_cfg or cfg_err == false then
    return false, "setFluidInterfaceConfiguration failed: " .. tostring(cfg_err), active
  end
  active.fluids[1] = { side = side, db_slot = db_slot, spec = spec }
  self:_push_slot(active, db_slot)
  return true, nil, active
end

function InterfaceStock:clear_item(active)
  active = active or {}
  local machine = active.machine
  local iface = active.iface
  if not iface and machine then
    local got = self:_iface(machine)
    if got then iface = got end
  end
  if not iface then return false, "me_interface proxy unavailable for clear item" end
  for _, item_cfg in ipairs(active.items or {}) do
    pcall(iface.setInterfaceConfiguration, item_cfg.iface_slot)
  end
  return true
end

function InterfaceStock:clear_fluid(active)
  active = active or {}
  local machine = active.machine
  local iface = active.iface
  if not iface and machine then
    local got = self:_iface(machine)
    if got then iface = got end
  end
  if not iface then return false, "me_interface proxy unavailable for clear fluid" end
  for _, fluid_cfg in ipairs(active.fluids or {}) do
    pcall(iface.setFluidInterfaceConfiguration, fluid_cfg.side)
  end
  return true
end

function InterfaceStock:stock_batch(machine, manifest)
  manifest = manifest or {}
  local iface, if_err = self:_iface(machine)
  if not iface then return false, if_err end
  if not iface.setInterfaceConfiguration then
    return false, "me_interface missing setInterfaceConfiguration"
  end
  if not iface.setFluidInterfaceConfiguration then
    return false, "me_interface missing setFluidInterfaceConfiguration"
  end

  local items = manifest.items or {}
  local fluids = manifest.fluids or {}
  local slot_start = self:_item_slot_start(machine)
  local slot_limit = self:_item_slot_limit(machine)
  if #items > slot_limit then
    return false, string.format(
      "manifest has %d items but interface_item_slots=%d",
      #items, slot_limit
    )
  end

  local active = {
    machine = machine,
    iface = iface,
    items = {},
    fluids = {},
    db_slots = {},
  }

  for i, spec in ipairs(items) do
    local iface_slot = slot_start + (i - 1)
    local ok_slot, db_slot = self.descriptor_cache:ensure_item(iface, spec)
    if not ok_slot then return false, tostring(db_slot), active end
    local ok_cfg, cfg_err = pcall(iface.setInterfaceConfiguration, iface_slot, self.config.database_address, db_slot, spec.count or 1)
    if not ok_cfg or cfg_err == false then
      return false, "setInterfaceConfiguration failed: " .. tostring(cfg_err), active
    end
    active.items[#active.items + 1] = {
      iface_slot = iface_slot,
      db_slot = db_slot,
      spec = spec,
    }
    self:_push_slot(active, db_slot)
  end

  local fluid_side = self:_fluid_side(machine)
  for _, spec in ipairs(fluids) do
    local ok_slot, db_slot = self.descriptor_cache:ensure_fluid(iface, spec)
    if not ok_slot then return false, tostring(db_slot), active end
    local ok_cfg, cfg_err = pcall(iface.setFluidInterfaceConfiguration, fluid_side, self.config.database_address, db_slot)
    if not ok_cfg or cfg_err == false then
      return false, "setFluidInterfaceConfiguration failed: " .. tostring(cfg_err), active
    end
    active.fluids[#active.fluids + 1] = {
      side = fluid_side,
      db_slot = db_slot,
      spec = spec,
    }
    self:_push_slot(active, db_slot)
  end

  return true, nil, active
end

function InterfaceStock:clear_interfaces(machine, active)
  active = active or {}
  local iface = active.iface
  if not iface then
    local got = self:_iface(machine)
    if got then iface = got end
  end
  if not iface then return false, "me_interface proxy unavailable for clear" end

  for _, item_cfg in ipairs(active.items or {}) do
    pcall(iface.setInterfaceConfiguration, item_cfg.iface_slot)
  end
  for _, fluid_cfg in ipairs(active.fluids or {}) do
    pcall(iface.setFluidInterfaceConfiguration, fluid_cfg.side)
  end
  return true
end

function InterfaceStock:release_batch(active)
  if not active then return 0 end
  local machine = active.machine
  if machine then
    self:clear_interfaces(machine, active)
  end
  return self.descriptor_cache:release_slots(active.db_slots or {})
end

function InterfaceStock:wait_pull_ready(item_tp, fluid_tp, machine, manifest, timeout_s)
  manifest = manifest or {}
  local start_ms = os.clock and os.clock() or 0
  local deadline = start_ms + (timeout_s or 0)
  local item_side = machine.side_buffer
  local fluid_side = machine.side_fluid_buffer or machine.side_buffer

  local function has_items()
    local items = manifest.items or {}
    if #items == 0 then return true end
    if not item_tp or not item_tp.getInventorySize then return false end
    local size = item_tp.getInventorySize(item_side) or 0
    for _, want in ipairs(items) do
      local found = false
      for slot = 1, size do
        local st = item_tp.getStackInSlot and item_tp.getStackInSlot(item_side, slot)
        if stack_matches(st, want) and (st.size or 0) > 0 then
          found = true
          break
        end
      end
      if not found then return false end
    end
    return true
  end

  local function has_fluids()
    local fluids = manifest.fluids or {}
    if #fluids == 0 then return true end
    return fluid_level(fluid_tp, fluid_side) > 0
  end

  repeat
    if has_items() and has_fluids() then return true end
    self.sleep(0.1)
    start_ms = os.clock and os.clock() or (start_ms + 0.1)
  until start_ms >= deadline

  return false
end

return InterfaceStock
