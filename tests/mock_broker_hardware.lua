--[[
  AutoOS — Realistic mock hardware for subnet broker desktop tests

  Models real OC/GTNH behavior instead of fabricating success:
    * transferItem moves only stacks that actually exist
    * interface item stocking pulls from the shared ME network (decrements it)
    * fluid stocking needs an ae2fc fluid drop descriptor in the database and
      a Fluid Discretizer (drops as ME items); fills a SMALL per-side buffer
      that refills between transposer pulls — exercising the pump loop
    * getTankLevel THROWS "invalid tank index" on faces without tanks,
      matching the in-game crash
    * inventories/tanks are only visible on the faces things are mounted on

  Options for Mock.new:
    machines          config rows (use Mock.machines_from_config(Config))
    database_address  OC database UUID
    network_items     { {name, damage, label, size}, ... }
    network_fluids    { [label] = amount_mb, ... }
    discretizer       default true — expose fluids as "drop of <label>" items
    fluid_buffer      default 1000 — interface tank size per stocking config
]]

local Mock = {}

local FLUID_DROP = "ae2fc:fluid_drop"

local function filter_match(stack, filter)
  if type(filter) ~= "table" then return true end
  if filter.name and stack.name ~= filter.name then return false end
  if filter.damage ~= nil and stack.damage ~= filter.damage then return false end
  if filter.label and (stack.label or ""):lower() ~= filter.label:lower() then return false end
  return true
end

function Mock.new(opts)
  opts = opts or {}

  local stats = {
    getSensorInformation = 0,
    setInterfaceConfiguration = 0,
    setFluidInterfaceConfiguration = 0,
    store = 0,
    transferItem = 0,
    transferFluid = 0,
  }

  local fluid_buffer = opts.fluid_buffer or 1000
  local discretizer = opts.discretizer ~= false

  -- Shared subnet ME network ------------------------------------------------
  local network = {
    items = {},
    fluids = {},
  }
  for _, it in ipairs(opts.network_items or {}) do
    network.items[#network.items + 1] = {
      name = it.name, damage = it.damage or 0, label = it.label, size = it.size or 1,
    }
  end
  for label, amount in pairs(opts.network_fluids or {}) do
    network.fluids[label] = amount
  end

  local function visible_items()
    local out = {}
    for _, it in ipairs(network.items) do
      if (it.size or 0) > 0 then out[#out + 1] = it end
    end
    if discretizer then
      for label, amount in pairs(network.fluids) do
        if amount > 0 then
          out[#out + 1] = {
            name = FLUID_DROP, damage = 0,
            label = "drop of " .. label, size = amount,
          }
        end
      end
    end
    return out
  end

  local function find_network_item(filter)
    for _, it in ipairs(visible_items()) do
      if filter_match(it, filter) then return it end
    end
    return nil
  end

  local function take_network_item(name, damage, count)
    for _, it in ipairs(network.items) do
      if it.name == name and it.damage == damage and (it.size or 0) >= count then
        it.size = it.size - count
        return true
      end
    end
    return false
  end

  -- Database ------------------------------------------------------------------
  local db_slots = {}
  local db_proxy = {
    set = function(slot, name, damage)
      db_slots[slot] = { name = name, damage = damage or 0 }
      return true
    end,
    get = function(slot)
      return db_slots[slot]
    end,
    clear = function(slot)
      local had = db_slots[slot] ~= nil
      db_slots[slot] = nil
      return had
    end,
  }

  -- Lanes -----------------------------------------------------------------------
  local lanes = {}          -- by machine id
  local proxies = {}        -- by address
  local component_types = {}

  for _, m in ipairs(opts.machines or {}) do
    local lane = {
      row = m,
      healthy = true,
      active = false,
      has_work = false,
      fault_message = "Problems: 1",
      iface_inv = {},        -- interface exposed item slots (stocked items)
      item_cfg = nil,        -- active item stocking config
      fluid_cfg = {},        -- [me_side] = fluid label
      fluid_tank = {},       -- [me_side] = mB currently buffered
      bus_inv = {},          -- GT input bus slots
      hatch_mb = 0,          -- fluid delivered to the GT hatch
    }
    lanes[m.id] = lane

    component_types[m.gt_address] = "gt_machine"
    component_types[m.interface_address] = "me_interface"
    component_types[m.transposer_address] = "transposer"

    -- AE2 keeps configured slots stocked: refill from network when empty.
    local function restock_items()
      local cfg = lane.item_cfg
      if not cfg then return end
      local slot = cfg.slot
      if lane.iface_inv[slot] then return end
      local entry = db_slots[cfg.db_index]
      if not entry then return end
      if take_network_item(entry.name, entry.damage, 1) then
        lane.iface_inv[slot] = { name = entry.name, damage = entry.damage, size = 1 }
      end
    end

    local function refill_tank(me_side)
      local label = lane.fluid_cfg[me_side]
      if not label then return end
      local available = network.fluids[label] or 0
      local current = lane.fluid_tank[me_side] or 0
      local want = fluid_buffer - current
      if want <= 0 or available <= 0 then return end
      local moved = math.min(want, available)
      network.fluids[label] = available - moved
      lane.fluid_tank[me_side] = current + moved
    end

    -- ME interface --------------------------------------------------------------
    proxies[m.interface_address] = {
      setInterfaceConfiguration = function(slot, db_addr, db_index, count)
        stats.setInterfaceConfiguration = stats.setInterfaceConfiguration + 1
        if db_addr == nil then
          -- Clear: stocked item returns to the network.
          local stack = lane.iface_inv[slot]
          if stack then
            network.items[#network.items + 1] = stack
            lane.iface_inv[slot] = nil
          end
          lane.item_cfg = nil
          return true
        end
        local entry = db_slots[db_index]
        if not entry then return false end
        lane.item_cfg = { slot = slot, db_index = db_index, count = count or 1 }
        restock_items()
        return true
      end,

      setFluidInterfaceConfiguration = function(side, db_addr, db_index)
        stats.setFluidInterfaceConfiguration = stats.setFluidInterfaceConfiguration + 1
        if db_addr == nil then
          -- Clear: buffered fluid returns to the network.
          local label = lane.fluid_cfg[side]
          local buffered = lane.fluid_tank[side] or 0
          if label and buffered > 0 then
            network.fluids[label] = (network.fluids[label] or 0) + buffered
          end
          lane.fluid_cfg[side] = nil
          lane.fluid_tank[side] = nil
          return true
        end
        local entry = db_slots[db_index]
        if not entry or not entry.name:find("fluid_drop", 1, true) then
          -- Real interface accepts the call but stocks nothing useful.
          lane.fluid_cfg[side] = nil
          lane.fluid_tank[side] = nil
          return true
        end
        local label = (entry.label or ""):gsub("^drop of ", "")
        if not network.fluids[label] then
          lane.fluid_cfg[side] = nil
          return true
        end
        lane.fluid_cfg[side] = label
        lane.fluid_tank[side] = 0
        refill_tank(side)
        return true
      end,

      store = function(filter, db_addr, slot, count)
        stats.store = stats.store + 1
        local it = find_network_item(filter)
        if not it then return false end
        db_slots[slot] = { name = it.name, damage = it.damage or 0, label = it.label }
        return true
      end,

      getItemsInNetwork = function(filter)
        local out = {}
        for _, it in ipairs(visible_items()) do
          if filter_match(it, filter) then out[#out + 1] = it end
        end
        return out
      end,

      getFluidsInNetwork = function()
        local out = {}
        for label, amount in pairs(network.fluids) do
          out[#out + 1] = { label = label, name = label:lower():gsub(" ", "_"), amount = amount }
        end
        return out
      end,
    }

    -- Transposer ---------------------------------------------------------------
    -- Which lane structure a transposer face touches.
    local function face_role(side)
      if side == (m.interface_item_side or 1) then return "interface" end
      if side == (m.item_bus_side or 0) then return "bus" end
      if side == (m.fluid_push_side or 2) then return "hatch" end
      return nil
    end

    -- The interface's internal tank is visible on the transposer's interface
    -- face only when the config targets the face touching the transposer.
    local function pull_tank_mb(side)
      if side ~= (m.fluid_pull_side or m.interface_item_side or 1) then return nil end
      local me_side = m.interface_fluid_side or 0
      if lane.fluid_cfg[me_side] == nil then return nil end
      return lane.fluid_tank[me_side] or 0, me_side
    end

    proxies[m.transposer_address] = {
      getInventorySize = function(side)
        local role = face_role(side)
        if role == "interface" then return 9 end
        if role == "bus" then return 16 end
        return 0
      end,

      getStackInSlot = function(side, slot)
        local role = face_role(side)
        if role == "interface" then
          restock_items()
          return lane.iface_inv[slot]
        end
        if role == "bus" then return lane.bus_inv[slot] end
        return nil
      end,

      transferItem = function(from_side, to_side, count, from_slot, to_slot)
        stats.transferItem = stats.transferItem + 1
        count = count or 1
        local from_role = face_role(from_side)
        local to_role = face_role(to_side)

        local src
        if from_role == "interface" then
          restock_items()
          src = lane.iface_inv
        elseif from_role == "bus" then
          src = lane.bus_inv
        else
          return 0
        end

        local stack = from_slot and src[from_slot]
        if not stack or (stack.size or 0) < 1 then return 0 end

        local moved = math.min(count, stack.size)
        local payload = { name = stack.name, damage = stack.damage, size = moved }

        if to_role == "bus" then
          local dest = to_slot or 1
          if lane.bus_inv[dest] then return 0 end  -- occupied slot blocks
          lane.bus_inv[dest] = payload
        elseif to_role == "interface" then
          local dest = to_slot or 1
          if lane.iface_inv[dest] then return 0 end
          lane.iface_inv[dest] = payload
        else
          return 0
        end

        stack.size = stack.size - moved
        if stack.size <= 0 then src[from_slot] = nil end
        restock_items()
        return moved
      end,

      transferFluid = function(from_side, to_side, amount)
        stats.transferFluid = stats.transferFluid + 1
        amount = amount or 1000
        local tank_mb, me_side = pull_tank_mb(from_side)
        if tank_mb == nil then
          return false, "no fluid handler"
        end
        if face_role(to_side) ~= "hatch" then
          return false, "no fluid handler"
        end
        if tank_mb < 1 then
          refill_tank(me_side)
          tank_mb = lane.fluid_tank[me_side] or 0
          if tank_mb < 1 then return true, 0 end
        end
        local moved = math.min(amount, tank_mb)
        lane.fluid_tank[me_side] = tank_mb - moved
        lane.hatch_mb = lane.hatch_mb + moved
        refill_tank(me_side)
        return true, moved
      end,

      getTankCount = function(side)
        if pull_tank_mb(side) ~= nil then return 1 end
        if face_role(side) == "hatch" then return 1 end
        return 0
      end,

      getTankLevel = function(side, tank)
        local tank_mb = pull_tank_mb(side)
        if tank_mb ~= nil and (tank or 1) == 1 then return tank_mb end
        if face_role(side) == "hatch" and (tank or 1) == 1 then return lane.hatch_mb end
        error("invalid tank index")  -- matches real OC on faces without tanks
      end,
    }

    -- GT machine -----------------------------------------------------------------
    proxies[m.gt_address] = {
      getSensorInformation = function()
        stats.getSensorInformation = stats.getSensorInformation + 1
        if not lane.healthy then return { lane.fault_message } end
        return { "Problems: 0 Efficiency: 100.0 %" }
      end,
      isWorkAllowed = function() return true end,
      isMachineActive = function() return lane.active end,
      hasWork = function() return lane.has_work end,
    }
  end

  if opts.database_address then
    component_types[opts.database_address] = "database"
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
    stats = stats,
    network = network,
    db_slots = db_slots,

    set_machine_fault = function(id, faulted, message)
      local lane = lanes[id]
      if lane then
        lane.healthy = not faulted
        if message then lane.fault_message = message end
      end
    end,

    set_machine_busy = function(id, active, has_work)
      local lane = lanes[id]
      if lane then
        lane.active = active == true
        lane.has_work = has_work == true
      end
    end,

    break_component = function(address)
      component_types[address] = nil
      proxies[address] = nil
    end,

    hatch_mb = function(id)
      return lanes[id] and lanes[id].hatch_mb or 0
    end,

    bus_stack = function(id, slot)
      return lanes[id] and lanes[id].bus_inv[slot or 1] or nil
    end,

    put_bus_stack = function(id, slot, stack)
      if lanes[id] then lanes[id].bus_inv[slot or 1] = stack end
    end,
  }
end

function Mock.machines_from_config(config)
  local list = {}
  for _, m in ipairs(config.machines) do
    list[#list + 1] = {
      id = m.id,
      gt_address = m.gt_address,
      interface_address = m.interface_address or ("mock-iface-" .. m.id),
      transposer_address = m.transposer_address,
      interface_item_side = m.interface_item_side or m.recover_side,
      recover_side = m.recover_side or m.interface_item_side,
      item_bus_side = m.item_bus_side,
      fluid_pull_side = m.fluid_pull_side,
      fluid_push_side = m.fluid_push_side,
      interface_fluid_side = m.interface_fluid_side,
      interface_item_slot = m.interface_item_slot or m.recover_slot,
      input_slot = m.input_slot,
    }
  end
  return list
end

return Mock
