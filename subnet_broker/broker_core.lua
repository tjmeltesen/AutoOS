--[[
  AutoOS — Broker Core

  Batch dispatch planner. Phase 2: machine_poll active pool + optional circuit push.
  Phase 3 adds ME interface poll loop.

  References: README.md §4
]]

local config = require("config")
local balancer = require("load_balancer")

local BrokerCore = {}

local DEFAULT_UNIT = 1000
local _deps = {}

function BrokerCore.set_deps(deps)
  _deps = deps or {}
end

local function try_require_component()
  local ok, component = pcall(require, "component")
  if ok then
    return component
  end
  return nil
end

local function get_machine_poll(opts)
  if opts.machine_poll then
    return opts.machine_poll
  end
  if _deps.machine_poll then
    return _deps.machine_poll
  end
  local component = try_require_component()
  if component then
    local ok, MachinePoll = pcall(require, "machine_poll")
    if ok then
      return MachinePoll.new({ config = config, component = component })
    end
  end
  return nil
end

local function get_circuit_manager(opts)
  if opts.circuit_manager then
    return opts.circuit_manager
  end
  if _deps.circuit_manager then
    return _deps.circuit_manager
  end
  local component = try_require_component()
  if component then
    local ok, CircuitManager = pcall(require, "circuit_manager")
    if ok then
      return CircuitManager.new({ config = config, component = component })
    end
  end
  return nil
end

local function circuit_damage_for(recipe_key, opts)
  if opts.circuit_damage then
    return opts.circuit_damage
  end
  local map = config.recipe_circuit_damage
  if map and map[recipe_key] then
    return map[recipe_key]
  end
  return nil
end

---@param circuit_token_id string Recipe key in config.constraints.recipe_baselines
---@param current_buffer_volume number Total fluid (mB/L) available for the batch
---@param active_pool table[]|nil Defaults to polled healthy machines when omitted
---@param opts table|nil { machine_poll, circuit_manager, push_circuits, circuit_damage, poll_results }
---@return boolean success
function BrokerCore.process_batch(circuit_token_id, current_buffer_volume, active_pool, opts)
  opts = opts or {}

  print(string.format("\n[AutoOS] Subnet '%s' Initializing Universal Run...", config.subnet_id))

  local recipe_rules = config.constraints
    and config.constraints.recipe_baselines
    and config.constraints.recipe_baselines[circuit_token_id]

  local minimum_unit = DEFAULT_UNIT
  if recipe_rules and recipe_rules.fluid_requirement then
    minimum_unit = recipe_rules.fluid_requirement
  else
    print(string.format(
      "[AutoOS] Warning: no recipe baseline for '%s'; using default %dL per operation",
      tostring(circuit_token_id),
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
    "[AutoOS] Recipe '%s' — %dL batch, %dL per op → %d operations total (%d machines in pool)",
    tostring(circuit_token_id),
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

  local damage = circuit_damage_for(circuit_token_id, opts)
  local push_circuits = opts.push_circuits
  if push_circuits == nil then
    push_circuits = true
  end
  local cm = push_circuits and damage and get_circuit_manager(opts) or nil

  for _, machine in ipairs(config.machines) do
    local target = allocations[machine.id]
    local in_pool = false
    for _, m in ipairs(active_pool) do
      if m.id == machine.id then
        in_pool = true
        break
      end
    end

    if not in_pool then
      print(string.format(" -> [Dispatch -> %s] 0 Ops allocated. Machine safe and clean.", machine.id))
    elseif target and target.operations > 0 then
      print(string.format(
        " -> [Dispatch -> %s] Routing %d Operations (%dL) to bus [%s] hatch [%s]",
        machine.id,
        target.operations,
        target.allocated_volume,
        target.bus_in,
        target.hatch_fluid
      ))
      if cm then
        local ok_push, push_err = cm:push_circuit(machine.id, damage)
        if ok_push then
          print(string.format(" -> [Circuit -> %s] Pushed configuration %d", machine.id, damage))
        else
          print(string.format(" -> [Circuit -> %s] Push failed: %s", machine.id, tostring(push_err)))
        end
      end
    else
      print(string.format(" -> [Dispatch -> %s] 0 Ops allocated. Machine safe and clean.", machine.id))
    end
  end

  return true
end

return BrokerCore
