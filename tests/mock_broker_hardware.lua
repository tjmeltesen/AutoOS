--[[
  AutoOS — Mock hardware for subnet broker Phase 2 desktop tests
]]

local Mock = {}

function Mock.new(opts)
  opts = opts or {}

  local stats = {
    getSensorInformation = 0,
    setExportConfiguration = 0,
    exportIntoSlot = 0,
    transferItem = 0,
  }

  local machines = {}
  for _, m in ipairs(opts.machines or {}) do
    machines[m.id] = {
      id = m.id,
      gt_address = m.gt_address,
      bus_in = m.bus_in,
      healthy = m.healthy ~= false,
      fault_message = m.fault_message or "Machine needs a wrench!",
      sensor = m.sensor or { "Problems: 0 Efficiency: 100.0 %" },
    }
  end

  local export_buses = {}
  local transposers = {}
  local component_types = {}

  for _, m in ipairs(opts.machines or {}) do
    component_types[m.gt_address] = "gt_machine"
    if m.bus_type == "transposer" then
      component_types[m.bus_in] = "transposer"
    else
      component_types[m.bus_in] = "me_exportbus"
    end
    component_types[m.hatch_fluid] = "aemultipart"

    export_buses[m.bus_in] = {
      setExportConfiguration = function(side, db, slot)
        stats.setExportConfiguration = stats.setExportConfiguration + 1
        export_buses[m.bus_in]._last = { side = side, db = db, slot = slot }
        return true
      end,
      exportIntoSlot = function(side, slot)
        stats.exportIntoSlot = stats.exportIntoSlot + 1
        export_buses[m.bus_in]._export = { side = side, slot = slot }
        return true
      end,
    }

    local vault_inv = opts.vault_inventory or {
      { name = "gregtech:gt.integrated_circuit", damage = 14, size = 64 },
    }
    local bus_inv = {}

    transposers[m.bus_in] = nil
    local tp_addr = m.transposer_address or opts.vault_address or "vault-tp"
    component_types[tp_addr] = "transposer"

    local inv = { [2] = vault_inv, [3] = bus_inv }

    transposers[tp_addr] = {
      _inv = inv,
      getInventorySize = function(side)
        return #(inv[side] or {})
      end,
      getStackInSlot = function(side, slot)
        local side_inv = inv[side]
        if not side_inv then return nil end
        return side_inv[slot]
      end,
      transferItem = function(from_side, to_side, count, from_slot, to_slot)
        stats.transferItem = stats.transferItem + 1
        local from_inv = inv[from_side]
        local to_inv = inv[to_side]
        if not from_inv or not to_inv then return 0 end
        local stack = from_inv[from_slot]
        if not stack or (stack.size or 0) < 1 then return 0 end
        to_inv[to_slot or 1] = {
          name = stack.name,
          damage = stack.damage,
          size = 1,
        }
        stack.size = stack.size - 1
        if stack.size <= 0 then
          from_inv[from_slot] = nil
        end
        return 1
      end,
    }
  end

  if opts.vault_address then
    component_types[opts.vault_address] = "transposer"
  end
  if opts.database_address then
    component_types[opts.database_address] = "database"
  end

  local function gt_proxy(machine_id)
    local m = machines[machine_id]
    if not m then return nil end
    return {
      getSensorInformation = function()
        stats.getSensorInformation = stats.getSensorInformation + 1
        if not m.healthy then
          return { m.fault_message }
        end
        return m.sensor
      end,
      isWorkAllowed = function() return true end,
      isMachineActive = function() return false end,
      hasWork = function() return false end,
    }
  end

  local proxies = {}
  for id, m in pairs(machines) do
    proxies[m.gt_address] = gt_proxy(id)
  end
  for addr, bus in pairs(export_buses) do
    proxies[addr] = bus
  end
  for addr, tp in pairs(transposers) do
    proxies[addr] = tp
  end

  local component = {
    list = function()
      local t = {}
      for addr, ctype in pairs(component_types) do
        t[addr] = ctype
      end
      return t
    end,
    proxy = function(address, hint)
      return proxies[address]
    end,
  }

  return {
    component = component,
    component_types = component_types,
    stats = stats,
    machines = machines,
    export_buses = export_buses,
    transposers = transposers,
    set_machine_fault = function(id, faulted, message)
      local m = machines[id]
      if m then
        m.healthy = not faulted
        if message then m.fault_message = message end
      end
    end,
  }
end

function Mock.machines_from_config(config)
  local list = {}
  for _, m in ipairs(config.machines) do
    list[#list + 1] = {
      id = m.id,
      gt_address = m.gt_address,
      bus_in = m.bus_in,
      hatch_fluid = m.hatch_fluid,
      bus_type = m.bus_type or "me_exportbus",
      transposer_address = m.transposer_address,
    }
  end
  return list
end

return Mock
