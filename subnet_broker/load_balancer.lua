--[[
  AutoOS — Load Balancer (Phase 1)

  Pure math: quantize bulk fluid into discrete GT operations and distribute
  whole operation counts across an active machine pool. No hardware calls.

  References: README.md §4, references/performance-pitfalls.md
]]

local LoadBalancer = {}

---@param total_fluid number
---@param unit_requirement number
---@return integer O
function LoadBalancer.total_operations(total_fluid, unit_requirement)
  return math.floor(total_fluid / unit_requirement)
end

---@param active_pool table[] Ordered machine config rows from config.machines
---@param total_fluid number
---@param unit_requirement number
---@return table|nil distribution_map
---@return string|nil err
function LoadBalancer.calculate_distribution(active_pool, total_fluid, unit_requirement)
  if type(unit_requirement) ~= "number" or unit_requirement <= 0 then
    return nil, "Invalid unit requirement."
  end

  local M = #active_pool
  if M == 0 then
    return nil, "No operational machines found."
  end

  local O = LoadBalancer.total_operations(total_fluid, unit_requirement)
  if O == 0 then
    return nil, "Batch volume falls short of minimum recipe boundaries."
  end

  local base_ops = math.floor(O / M)
  local remainder_ops = O % M
  local distribution_map = {}

  for i, machine in ipairs(active_pool) do
    local assigned_ops = base_ops
    if i <= remainder_ops then
      assigned_ops = assigned_ops + 1
    end

    distribution_map[machine.id] = {
      bus_in = machine.bus_in,
      hatch_fluid = machine.hatch_fluid,
      gt_address = machine.gt_address,
      operations = assigned_ops,
      allocated_volume = assigned_ops * unit_requirement,
    }
  end

  return distribution_map, nil
end

return LoadBalancer
