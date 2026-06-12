--[[
  AutoOS — Broker Core (1:1:1 lane topology)

  Reads subnet batch volume (manual process_batch for now), quantizes ops,
  polls healthy machines, then for each lane sequentially:
    set ME interface stocking → transposer transfer → clear interface.

  References: README.md Architecture Revision Addendum
]]

local config = require("config")
local balancer = require("load_balancer")
local DescriptorCache = require("descriptor_cache")
local LaneSides = require("lane_sides")

local BrokerCore = {}
BrokerCore.__index = BrokerCore

local DEFAULT_UNIT = 1000
local _deps = {}

function BrokerCore.set_deps(deps)
  _deps = deps or {}
end

local function try_require_component()
  local ok, component = pcall(require, "component")
  if ok then return component end
  return nil
end

local function get_machine_poll(opts)
  if opts.machine_poll then return opts.machine_poll end
  if _deps.machine_poll then return _deps.machine_poll end
  local component = try_require_component()
  if component then
    local ok, MachinePoll = pcall(require, "machine_poll")
    if ok then
      return MachinePoll.new({ config = config, component = component })
    end
  end
  return nil
end

local function recipe_rules(recipe_key)
  return config.constraints
    and config.constraints.recipe_baselines
    and config.constraints.recipe_baselines[recipe_key]
end

local function find_machine_row(machine_id)
  for _, m in ipairs(config.machines) do
    if m.id == machine_id then return m end
  end
  return nil
end

local function get_circuit_manager(opts)
  if opts.circuit_manager then return opts.circuit_manager end
  if _deps.circuit_manager then return _deps.circuit_manager end
  local component = opts.component or _deps.component or try_require_component()
  if component then
    local ok, CircuitManager = pcall(require, "circuit_manager")
    if ok then
      return CircuitManager.new({ config = config, component = component })
    end
  end
  return nil
end

local function circuit_damage_for(recipe_key, opts)
  if opts.circuit_damage then return opts.circuit_damage end
  local rules = recipe_rules(recipe_key)
  if rules and rules.circuit_damage then return rules.circuit_damage end
  local map = config.recipe_circuit_damage
  if map and map[recipe_key] then return map[recipe_key] end
  return nil
end

local function get_descriptor_cache(opts, component)
  if opts.descriptor_cache then return opts.descriptor_cache end
  if _deps.descriptor_cache then return _deps.descriptor_cache end
  component = component or opts.component or _deps.component or try_require_component()
  if component then
    return DescriptorCache.new({ config = config, component = component })
  end
  return nil
end

local function proxy(component, address, hint)
  if not component or not component.proxy then return nil end
  local ok, p = pcall(component.proxy, address, hint)
  if ok and p then return p end
  ok, p = pcall(component.proxy, address)
  if ok then return p end
  return nil
end

--- Configure lane ME interface, transposer transfer, clear interface.
---@return boolean ok
---@return string|nil err
function BrokerCore.execute_lane(machine_row, allocation, recipe_key, component, opts)
  opts = opts or {}
  local rules = recipe_rules(recipe_key)
  if not rules then
    return false, "no recipe baseline for " .. tostring(recipe_key)
  end

  local db = config.database_address
  if not db or db == "" then
    return false, "database_address not configured"
  end

  local iface = proxy(component, machine_row.interface_address, "me_interface")
  if not iface then
    return false, "me_interface not available at " .. tostring(machine_row.interface_address)
  end

  local tp = proxy(component, machine_row.transposer_address, "transposer")
  if not tp then
    return false, "transposer not available at " .. tostring(machine_row.transposer_address)
  end

  local volume = allocation.allocated_volume
  local kind = rules.kind or "fluid"
  local fluid_side = machine_row.interface_fluid_side or 1

  local push_circuit = opts.push_circuit
  if push_circuit == nil then push_circuit = opts.push_circuits end
  local recover_circuit = opts.recover_circuit
  if recover_circuit == nil then recover_circuit = opts.recover_circuits end

  local damage = circuit_damage_for(recipe_key, opts)
  if push_circuit and damage then
    local cm = get_circuit_manager(opts)
    if not cm then
      return false, "circuit_manager unavailable"
    end
    local ok_push, push_err = cm:push_circuit(machine_row.id, damage)
    if not ok_push then
      return false, "push_circuit failed: " .. tostring(push_err)
    end
  end

  if kind == "fluid" then
    local dc = get_descriptor_cache(opts, component)
    if not dc then
      return false, "descriptor_cache unavailable"
    end
    local ok_desc, db_slot = dc:ensure_fluid(iface, rules)
    if not ok_desc then
      return false, tostring(db_slot)
    end

    if iface.setFluidInterfaceConfiguration then
      local ok_cfg = iface.setFluidInterfaceConfiguration(fluid_side, db, db_slot)
      if not ok_cfg then
        return false, "setFluidInterfaceConfiguration failed"
      end
    end

    if tp.transferFluid then
      local ok_xfer, moved = tp.transferFluid(
        LaneSides.fluid_pull_side(machine_row),
        machine_row.fluid_push_side,
        volume
      )
      if not ok_xfer or (moved and moved < 1) then
        if iface.setFluidInterfaceConfiguration then
          iface.setFluidInterfaceConfiguration(fluid_side)
        end
        return false, "transferFluid failed: " .. tostring(moved)
      end
    elseif tp.transferItem then
      return false, "fluid recipe but transposer has no transferFluid"
    end

    if iface.setFluidInterfaceConfiguration then
      iface.setFluidInterfaceConfiguration(fluid_side)
    end
  else
    return false, "unsupported recipe kind: " .. tostring(kind)
  end

  if recover_circuit and damage then
    local cm = get_circuit_manager(opts)
    if not cm then
      return false, "circuit_manager unavailable for recovery"
    end
    local ok_rec, rec_err = cm:recover_circuit(machine_row.id, damage)
    if not ok_rec then
      return false, "recover_circuit failed: " .. tostring(rec_err)
    end
  end

  return true
end

--- Manual in-game test: push circuit + fluid for one lane, optionally recover circuit.
---@return boolean success
---@return string|nil err
function BrokerCore.manual_lane_test(machine_id, recipe_key, volume, opts)
  opts = opts or {}
  opts.push_circuit = opts.push_circuit ~= false
  opts.recover_circuit = opts.recover_circuit == true

  local row = find_machine_row(machine_id)
  if not row then
    return false, "unknown machine_id " .. tostring(machine_id)
  end

  local rules = recipe_rules(recipe_key)
  if not rules or not rules.fluid_requirement then
    return false, "no recipe baseline for " .. tostring(recipe_key)
  end

  local ops = balancer.total_operations(volume, rules.fluid_requirement)
  if ops < 1 then
    return false, "volume too low for one operation"
  end

  local allocation = {
    operations = ops,
    allocated_volume = ops * rules.fluid_requirement,
  }

  print(string.format(
    "[AutoOS] Manual lane test %s recipe=%s volume=%dL ops=%d recover=%s",
    machine_id,
    recipe_key,
    volume,
    ops,
    tostring(opts.recover_circuit)
  ))

  local component = opts.component or _deps.component or try_require_component()
  local execute_hw = opts.execute_hardware
  if execute_hw == nil then execute_hw = component ~= nil end

  if not execute_hw or not component then
    print("[AutoOS] Manual lane test: print-only (no component)")
    return true
  end

  return BrokerCore.execute_lane(row, allocation, recipe_key, component, opts)
end

---@param recipe_key string
---@param current_buffer_volume number
---@param active_pool table[]|nil
---@param opts table|nil execute_hardware, machine_poll, poll_results
---@return boolean success
function BrokerCore.process_batch(recipe_key, current_buffer_volume, active_pool, opts)
  opts = opts or {}

  print(string.format("\n[AutoOS] Subnet '%s' Initializing lane dispatch...", config.subnet_id))

  local rules = recipe_rules(recipe_key)
  local minimum_unit = DEFAULT_UNIT
  if rules and rules.fluid_requirement then
    minimum_unit = rules.fluid_requirement
  else
    print(string.format(
      "[AutoOS] Warning: no recipe baseline for '%s'; using default %dL per operation",
      tostring(recipe_key),
      DEFAULT_UNIT
    ))
  end

  local poll_results = opts.poll_results
  if active_pool == nil then
    local poll = get_machine_poll(opts)
    if poll then
      poll_results = poll_results or poll:poll_all()
      for _, machine in ipairs(config.machines) do
        local st = poll_results[machine.id]
        if st and st.available and not st.healthy then
          print(string.format(
            " -> [Pool] %s dropped — maintenance fault: %s",
            machine.id,
            tostring(st.fault_message or "unknown")
          ))
        elseif st and not st.available then
          print(string.format(" -> [Pool] %s dropped — gt_machine proxy unavailable", machine.id))
        end
      end
      active_pool = poll:build_active_pool(poll_results)
    else
      active_pool = config.machines
    end
  end

  local total_ops = balancer.total_operations(current_buffer_volume, minimum_unit)
  print(string.format(
    "[AutoOS] Recipe '%s' — %dL in subnet, %dL per op → %d operations (%d healthy lanes)",
    tostring(recipe_key),
    current_buffer_volume,
    minimum_unit,
    total_ops,
    #active_pool
  ))

  local allocations, err = balancer.calculate_distribution(active_pool, current_buffer_volume, minimum_unit)
  if not allocations then
    print("[Execution Halted] " .. tostring(err))
    return false
  end

  local component = opts.component or _deps.component or try_require_component()
  local execute_hw = opts.execute_hardware
  if execute_hw == nil then
    execute_hw = component ~= nil
  end

  -- One-at-a-time: process each healthy lane in pool order before moving to next.
  for _, machine in ipairs(active_pool) do
    local target = allocations[machine.id]
    if target and target.operations > 0 then
      print(string.format(
        " -> [Lane -> %s] %d ops (%dL) interface [%s] transposer [%s] item %d→%d fluid %d→%d",
        machine.id,
        target.operations,
        target.allocated_volume,
        machine.interface_address,
        machine.transposer_address,
        LaneSides.interface_item_side(machine),
        LaneSides.item_bus_side(machine) or -1,
        LaneSides.fluid_pull_side(machine),
        machine.fluid_push_side
      ))

      if execute_hw and component then
        local row = find_machine_row(machine.id) or machine
        local lane_opts = {}
        for k, v in pairs(opts) do lane_opts[k] = v end
        if lane_opts.push_circuits == nil then
          lane_opts.push_circuits = circuit_damage_for(recipe_key, opts) ~= nil
        end
        if lane_opts.recover_circuits == nil then
          lane_opts.recover_circuits = false
        end
        local ok_lane, lane_err = BrokerCore.execute_lane(row, target, recipe_key, component, lane_opts)
        if ok_lane then
          print(string.format(" -> [Lane -> %s] Transfer complete", machine.id))
        else
          print(string.format(" -> [Lane -> %s] Transfer failed: %s", machine.id, tostring(lane_err)))
          return false
        end
      end
    end
  end

  for _, machine in ipairs(config.machines) do
    local in_pool = false
    for _, m in ipairs(active_pool) do
      if m.id == machine.id then in_pool = true break end
    end
    local target = allocations[machine.id]
    if not in_pool or not target or target.operations == 0 then
      print(string.format(" -> [Lane -> %s] 0 ops — idle", machine.id))
    end
  end

  return true
end

return BrokerCore
