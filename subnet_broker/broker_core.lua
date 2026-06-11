--[[
  AutoOS — Broker Core (Phase 1 stub)

  Print-only batch dispatch planner. Phase 3 adds the ME poll loop and hardware
  routing via circuit_manager / machine_poll.

  References: README.md §4
]]

local config = require("config")
local balancer = require("load_balancer")

local BrokerCore = {}

local DEFAULT_UNIT = 1000

---@param circuit_token_id string Recipe key in config.constraints.recipe_baselines
---@param current_buffer_volume number Total fluid (mB/L) available for the batch
---@param active_pool table[]|nil Defaults to all config.machines when omitted
---@return boolean success
function BrokerCore.process_batch(circuit_token_id, current_buffer_volume, active_pool)
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

  active_pool = active_pool or config.machines

  local total_ops = balancer.total_operations(current_buffer_volume, minimum_unit)
  print(string.format(
    "[AutoOS] Recipe '%s' — %dL batch, %dL per op → %d operations total",
    tostring(circuit_token_id),
    current_buffer_volume,
    minimum_unit,
    total_ops
  ))

  local allocations, err = balancer.calculate_distribution(active_pool, current_buffer_volume, minimum_unit)
  if not allocations then
    print("[Execution Halted] " .. tostring(err))
    return false
  end

  for _, machine in ipairs(active_pool) do
    local target = allocations[machine.id]
    if target and target.operations > 0 then
      print(string.format(
        " -> [Dispatch -> %s] Routing %d Operations (%dL) to bus [%s] hatch [%s]",
        machine.id,
        target.operations,
        target.allocated_volume,
        target.bus_in,
        target.hatch_fluid
      ))
    else
      print(string.format(
        " -> [Dispatch -> %s] 0 Ops allocated. Machine safe and clean.",
        machine.id
      ))
    end
  end

  return true
end

return BrokerCore
