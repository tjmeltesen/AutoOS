--[[
  AutoOS — Mock hardware for subnet broker desktop tests (1:1:1 lanes)
]]

local Mock = {}

function Mock.new(opts)
  opts = opts or {}

  local stats = {
    getSensorInformation = 0,
    setFluidInterfaceConfiguration = 0,
    setInterfaceConfiguration = 0,
    store = 0,
    transferFluid = 0,
    transferItem = 0,
  }

  local network_items = opts.network_items or {
    { name = "gregtech:gt.integrated_circuit", damage = 14, label = "Integrated Circuit (14)", size = 64 },
  }
  local network_fluids = opts.network_fluids or {
    { label = "Molten Soldering Alloy", name = "molten_soldering_alloy", amount = 50000 },
  }

  local function filter_match(stack, filter)
    if type(filter) ~= "table" then return true end
    if filter.name and stack.name ~= filter.name then return false end
    if filter.damage ~= nil and stack.damage ~= filter.damage then return false end
    if filter.label and (stack.label or ""):lower() ~= filter.label:lower() then return false end
    if filter.tag and stack.tag ~= filter.tag then return false end
    return true
  end

  local machines = {}
  for _, m in ipairs(opts.machines or {}) do
    machines[m.id] = {
      id = m.id,
      gt_address = m.gt_address,
      interface_address = m.interface_address,
      transposer_address = m.transposer_address,
      interface_item_side = m.interface_item_side,
      item_bus_side = m.item_bus_side or m.pull_side or 0,
      fluid_pull_side = m.fluid_pull_side,
      fluid_push_side = m.fluid_push_side or 2,
      interface_fluid_side = m.interface_fluid_side or 1,
      interface_item_slot = m.interface_item_slot or 1,
      input_slot = m.input_slot or 0,
      healthy = m.healthy ~= false,
      fault_message = m.fault_message or "Problems: 1",
      sensor = m.sensor or { "Problems: 0 Efficiency: 100.0 %" },
    }
  end

  local interfaces = {}
  local transposers = {}
  local component_types = {}

  for _, m in ipairs(opts.machines or {}) do
    component_types[m.gt_address] = "gt_machine"
    component_types[m.interface_address] = "me_interface"
    component_types[m.transposer_address] = "transposer"

    interfaces[m.interface_address] = {
      _fluid_cfg = nil,
      _item_cfg = nil,
      setFluidInterfaceConfiguration = function(side, db, slot)
        stats.setFluidInterfaceConfiguration = stats.setFluidInterfaceConfiguration + 1
        if db == nil then
          interfaces[m.interface_address]._fluid_cfg = nil
          return true
        end
        interfaces[m.interface_address]._fluid_cfg = { side = side, db = db, slot = slot }
        return true
      end,
      setInterfaceConfiguration = function(a, b, c, d)
        stats.setInterfaceConfiguration = stats.setInterfaceConfiguration + 1
        if b == nil then
          interfaces[m.interface_address]._item_cfg = nil
          return true
        end
        interfaces[m.interface_address]._item_cfg = { slot = a, db = b, index = c, count = d }
        return true
      end,
      store = function(filter, db, slot, count)
        stats.store = stats.store + 1
        interfaces[m.interface_address]._last_store = { filter = filter, db = db, slot = slot }
        return true
      end,
      getItemsInNetwork = function(filter)
        local out = {}
        for _, it in ipairs(network_items) do
          if filter_match(it, filter) then out[#out + 1] = it end
        end
        return out
      end,
      getFluidsInNetwork = function()
        return network_fluids
      end,
    }

    local inv = opts.transposer_inventory and opts.transposer_inventory[m.transposer_address]
      or {
        [m.interface_item_side or 0] = {},
        [m.item_bus_side or m.pull_side or 0] = {},
        [m.fluid_pull_side or m.item_bus_side or 0] = {},
        [m.fluid_push_side or 2] = {},
      }

    transposers[m.transposer_address] = {
      _inv = inv,
      getInventorySize = function(side)
        return #(inv[side] or {})
      end,
      getStackInSlot = function(side, slot)
        local side_inv = inv[side]
        if not side_inv then return nil end
        return side_inv[slot]
      end,
      transferFluid = function(from_side, to_side, count)
        stats.transferFluid = stats.transferFluid + 1
        transposers[m.transposer_address]._last_fluid = { from_side, to_side, count }
        transposers[m.transposer_address]._last_fluid_sides = { from_side, to_side }
        return true, count
      end,
      transferItem = function(from_side, to_side, count, from_slot, to_slot)
        stats.transferItem = stats.transferItem + 1
        local dest = to_slot
        if dest == nil or dest < 1 then dest = 1 end
        local from_inv = inv[from_side] or {}
        local to_inv = inv[to_side] or {}
        inv[from_side] = from_inv
        inv[to_side] = to_inv
        if from_slot then
          local stack = from_inv[from_slot]
          if not stack or (stack.size or 0) < 1 then
            if from_side ~= to_side then
              to_inv[dest] = {
                name = "gregtech:gt.integrated_circuit",
                damage = 14,
                size = 1,
              }
              return 1
            end
            return 0
          end
          to_inv[dest] = {
            name = stack.name,
            damage = stack.damage,
            size = 1,
          }
          stack.size = stack.size - 1
          if stack.size <= 0 then from_inv[from_slot] = nil end
          return 1
        end
        to_inv[dest] = {
          name = "gregtech:gt.integrated_circuit",
          damage = 14,
          size = 1,
        }
        return count or 1
      end,
    }
  end

  local db_proxy
  if opts.database_address then
    component_types[opts.database_address] = "database"
    db_proxy = {
      _slots = {},
      set = function(slot, id, damage)
        db_proxy._slots[slot] = { name = id, damage = damage }
        return true
      end,
      get = function(slot)
        return db_proxy._slots[slot]
      end,
    }
  end

  local proxies = {}
  for id, m in pairs(machines) do
    proxies[m.gt_address] = {
      getSensorInformation = function()
        stats.getSensorInformation = stats.getSensorInformation + 1
        if not m.healthy then return { m.fault_message } end
        return m.sensor
      end,
      isWorkAllowed = function() return true end,
      isMachineActive = function() return false end,
      hasWork = function() return false end,
    }
  end
  for addr, iface in pairs(interfaces) do proxies[addr] = iface end
  for addr, tp in pairs(transposers) do proxies[addr] = tp end
  if opts.database_address and db_proxy then
    proxies[opts.database_address] = db_proxy
  end

  local component = {
    list = function()
      local t = {}
      for addr, ctype in pairs(component_types) do t[addr] = ctype end
      return t
    end,
    proxy = function(address)
      return proxies[address]
    end,
  }

  return {
    component = component,
    component_types = component_types,
    stats = stats,
    machines = machines,
    interfaces = interfaces,
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
      interface_address = m.interface_address,
      transposer_address = m.transposer_address,
      item_bus_side = m.item_bus_side,
      fluid_pull_side = m.fluid_pull_side,
      fluid_push_side = m.fluid_push_side,
      interface_fluid_side = m.interface_fluid_side,
      interface_item_slot = m.interface_item_slot,
      input_slot = m.input_slot,
    }
  end
  return list
end

return Mock
