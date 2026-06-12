--[[
  AutoOS — Broker Core (1:1:1 lane topology)

  process_batch(recipe_key, volume): quantize ops, poll healthy machines,
  then per lane sequentially:
    push circuit → stock + pump full fluid volume → clear interface
    (→ optionally recover circuit).

  A failed lane is logged and skipped; remaining lanes still run. The batch
  result is a summary table, not a single boolean abort.

  Options (process_batch / manual_lane_test opts):
    push_circuits     boolean  default: true when the recipe has circuit_damage
    recover_circuits  boolean  default: false on batch (machine still working)
    circuit_damage    integer  override recipe's circuit
    execute_hardware  boolean  default: true when the component API exists
    component / machine_poll / circuit_manager / descriptor_cache  injectable

  References: README.md Architecture Revision Addendum
]]

local config = require("config")
local balancer = require("load_balancer")
local DescriptorCache = require("descriptor_cache")
local FluidLane = require("fluid_lane")
local HW = require("hw")
local LaneSides = require("lane_sides")

local BrokerCore = {}

local _deps = {}

function BrokerCore.set_deps(deps)
  _deps = deps or {}
end

local function try_require_component()
  local ok, component = pcall(require, "component")
  if ok then return component end
  return nil
end

local function get_component(opts)
  return opts.component or _deps.component or try_require_component()
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

local function get_machine_poll(opts)
  if opts.machine_poll then return opts.machine_poll end
  if _deps.machine_poll then return _deps.machine_poll end
  local component = get_component(opts)
  if component then
    local ok, MachinePoll = pcall(require, "machine_poll")
    if ok then
      return MachinePoll.new({ config = config, component = component })
    end
  end
  return nil
end

local function get_circuit_manager(opts, component)
  if opts.circuit_manager then return opts.circuit_manager end
  if _deps.circuit_manager then return _deps.circuit_manager end
  component = component or get_component(opts)
  if component then
    local ok, CircuitManager = pcall(require, "circuit_manager")
    if ok then
      return CircuitManager.new({ config = config, component = component })
    end
  end
  return nil
end

local function get_descriptor_cache(opts, component)
  if opts.descriptor_cache then return opts.descriptor_cache end
  if _deps.descriptor_cache then return _deps.descriptor_cache end
  component = component or get_component(opts)
  if component then
    return DescriptorCache.new({ config = config, component = component })
  end
  return nil
end

local function circuit_damage_for(recipe_key, opts)
  if opts.circuit_damage then return opts.circuit_damage end
  local rules = recipe_rules(recipe_key)
  if rules then return rules.circuit_damage end
  return nil
end

--- Run one lane: circuit push → fluid pump → optional circuit recover.
---@param machine_row table machine config row
---@param allocation table { operations, allocated_volume }
---@param recipe_key string
---@param component table OC component API
---@param opts table see module header
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

  local iface, if_err = HW.require_proxy(component, "me_interface", machine_row.interface_address, "me_interface")
  if not iface then return false, if_err end

  local tp, tp_err = HW.require_proxy(component, "transposer", machine_row.transposer_address, "transposer")
  if not tp then return false, tp_err end

  local damage = circuit_damage_for(recipe_key, opts)
  local push_circuits = opts.push_circuits
  if push_circuits == nil then push_circuits = damage ~= nil end

  if push_circuits and damage then
    local cm = get_circuit_manager(opts, component)
    if not cm then
      return false, "circuit_manager unavailable"
    end
    local ok_push, push_err = cm:push_circuit(machine_row.id, damage)
    if not ok_push then
      return false, "push_circuit failed: " .. tostring(push_err)
    end
  end

  local kind = rules.kind or "fluid"
  if kind ~= "fluid" then
    return false, "unsupported recipe kind: " .. tostring(kind)
  end

  local dc = get_descriptor_cache(opts, component)
  if not dc then
    return false, "descriptor_cache unavailable"
  end
  local ok_desc, db_slot = dc:ensure_fluid(iface, rules)
  if not ok_desc then
    return false, tostring(db_slot)
  end

  local volume = allocation.allocated_volume
  local ok_fluid, moved, fluid_err = FluidLane.deliver(iface, tp, db, db_slot, machine_row, volume)
  if not ok_fluid then
    return false, string.format("fluid delivery failed (%d/%d mB): %s", moved, volume, tostring(fluid_err))
  end

  if opts.recover_circuits and damage then
    local cm = get_circuit_manager(opts, component)
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

--- Manual single-lane test: circuit + fluid, optional recover.
---@param machine_id string
---@param recipe_key string
---@param volume number
---@param opts table|nil
---@return boolean ok
---@return string|nil err
function BrokerCore.manual_lane_test(machine_id, recipe_key, volume, opts)
  opts = opts or {}
  if opts.push_circuits == nil then opts.push_circuits = true end
  opts.recover_circuits = opts.recover_circuits == true

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
    machine_id, recipe_key, volume, ops, tostring(opts.recover_circuits)
  ))

  local component = get_component(opts)
  local execute_hw = opts.execute_hardware
  if execute_hw == nil then execute_hw = component ~= nil end

  if not execute_hw or not component then
    print("[AutoOS] Manual lane test: print-only (no component)")
    return true
  end

  return BrokerCore.execute_lane(row, allocation, recipe_key, component, opts)
end

--- Build the healthy lane pool, logging dropped machines.
local function resolve_active_pool(opts)
  local poll = get_machine_poll(opts)
  if not poll then
    return config.machines
  end
  local poll_results = opts.poll_results or poll:poll_all()
  for _, machine in ipairs(config.machines) do
    local st = poll_results[machine.id]
    if st and st.available and not st.healthy then
      print(string.format(
        " -> [Pool] %s dropped — maintenance fault: %s",
        machine.id, tostring(st.fault_message or "unknown")
      ))
    elseif st and not st.available then
      print(string.format(" -> [Pool] %s dropped — gt_machine proxy unavailable", machine.id))
    end
  end
  return poll:build_active_pool(poll_results)
end

--- Dispatch a batch across healthy lanes. Failed lanes are skipped, not fatal.
---@param recipe_key string
---@param current_buffer_volume number total mB available in subnet
---@param active_pool table[]|nil override the healthy pool (tests)
---@param opts table|nil see module header
---@return boolean all_ok every dispatched lane succeeded
---@return table summary { dispatched, succeeded, failed, lanes = { [id] = { ok, err, volume } } }
function BrokerCore.process_batch(recipe_key, current_buffer_volume, active_pool, opts)
  opts = opts or {}

  print(string.format("\n[AutoOS] Subnet '%s' Initializing lane dispatch...", config.subnet_id))

  local rules = recipe_rules(recipe_key)
  if not rules or not rules.fluid_requirement then
    print(string.format("[Execution Halted] no recipe baseline for '%s'", tostring(recipe_key)))
    return false, { dispatched = 0, succeeded = 0, failed = 0, lanes = {} }
  end
  local minimum_unit = rules.fluid_requirement

  if active_pool == nil then
    active_pool = resolve_active_pool(opts)
  end

  local total_ops = balancer.total_operations(current_buffer_volume, minimum_unit)
  print(string.format(
    "[AutoOS] Recipe '%s' — %dL in subnet, %dL per op → %d operations (%d healthy lanes)",
    tostring(recipe_key), current_buffer_volume, minimum_unit, total_ops, #active_pool
  ))

  local allocations, err = balancer.calculate_distribution(active_pool, current_buffer_volume, minimum_unit)
  if not allocations then
    print("[Execution Halted] " .. tostring(err))
    return false, { dispatched = 0, succeeded = 0, failed = 0, lanes = {} }
  end

  local component = get_component(opts)
  local execute_hw = opts.execute_hardware
  if execute_hw == nil then execute_hw = component ~= nil end

  local summary = { dispatched = 0, succeeded = 0, failed = 0, lanes = {} }

  -- Sequential: one lane at a time, in pool order.
  for _, machine in ipairs(active_pool) do
    local target = allocations[machine.id]
    if target and target.operations > 0 then
      local iface_side, bus_side, fluid_pull, fluid_push = LaneSides.format_sides(machine)
      print(string.format(
        " -> [Lane -> %s] %d ops (%dL) interface [%s] transposer [%s] item %d→%d fluid %d→%d",
        machine.id, target.operations, target.allocated_volume,
        tostring(machine.interface_address), tostring(machine.transposer_address),
        iface_side, bus_side, fluid_pull, fluid_push
      ))

      if execute_hw and component then
        summary.dispatched = summary.dispatched + 1
        local lane_opts = {}
        for k, v in pairs(opts) do lane_opts[k] = v end
        if lane_opts.recover_circuits == nil then
          lane_opts.recover_circuits = false
        end

        local ok_lane, lane_err = BrokerCore.execute_lane(machine, target, recipe_key, component, lane_opts)
        summary.lanes[machine.id] = { ok = ok_lane, err = lane_err, volume = target.allocated_volume }
        if ok_lane then
          summary.succeeded = summary.succeeded + 1
          print(string.format(" -> [Lane -> %s] Transfer complete (%dL)", machine.id, target.allocated_volume))
        else
          summary.failed = summary.failed + 1
          print(string.format(" -> [Lane -> %s] Transfer FAILED: %s", machine.id, tostring(lane_err)))
        end
      end
    else
      print(string.format(" -> [Lane -> %s] 0 ops — idle", machine.id))
    end
  end

  if summary.dispatched > 0 then
    print(string.format(
      "[AutoOS] Batch done: %d/%d lanes succeeded%s",
      summary.succeeded, summary.dispatched,
      summary.failed > 0 and (" — " .. summary.failed .. " FAILED (see above)") or ""
    ))
  end

  return summary.failed == 0, summary
end

return BrokerCore
