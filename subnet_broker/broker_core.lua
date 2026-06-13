--[[
  AutoOS — Broker Core (1:1:1 lane topology)

  process_batch(recipe_key, volume): quantize ops, poll healthy machines,
  then per lane sequentially:
    push circuit → stock + pump full fluid volume → clear interface
    (→ optionally recover circuit).

  process_multi(jobs): multiple recipes in one call. By default only idle
  (not active / has_work) lanes receive work. Dispatches are interleaved
  round-robin across jobs so polyethylene and molten solder hit free machines
  in parallel rather than finishing one recipe before the next.

  A failed lane is logged and skipped; remaining lanes still run. The batch
  result is a summary table, not a single boolean abort.

  Options (process_batch / process_multi / manual_lane_test opts):
    push_circuits     boolean  default: true when the recipe has circuit_damage
    recover_circuits  boolean  default: false on batch (machine still working)
    circuit_damage    integer  override recipe's circuit
    execute_hardware  boolean  default: true when the component API exists
    only_idle         boolean  default: true on process_multi (skip busy lanes)
    interleave        boolean  default: true on process_multi (round-robin jobs)
    component / machine_poll / circuit_manager / descriptor_cache  injectable

  References: README.md Architecture Revision Addendum
]]

local config = require("config")
local balancer = require("load_balancer")
local DescriptorCache = require("descriptor_cache")
local FluidLane = require("fluid_lane")
local HW = require("hw")
local LaneSides = require("lane_sides")
local MachinePoll = require("machine_poll")

local BrokerCore = {}

local _deps = {}
local _shared_descriptor_cache = nil

function BrokerCore.set_deps(deps)
  _deps = deps or {}
  if deps.descriptor_cache then
    _shared_descriptor_cache = deps.descriptor_cache
  end
end

--- Drop the session descriptor cache (tests / fresh batch). Does not clear hardware DB.
function BrokerCore.reset_descriptor_cache()
  _shared_descriptor_cache = nil
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

local function get_descriptor_cache(opts, component)
  if opts.descriptor_cache then return opts.descriptor_cache end
  if _deps.descriptor_cache then return _deps.descriptor_cache end
  if _shared_descriptor_cache then return _shared_descriptor_cache end
  component = component or get_component(opts)
  if component then
    _shared_descriptor_cache = DescriptorCache.new({ config = config, component = component })
    return _shared_descriptor_cache
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
      return CircuitManager.new({
        config = config,
        component = component,
        descriptor_cache = get_descriptor_cache(opts, component),
      })
    end
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
      local lane_damage = circuit_damage_for(recipe_key, opts)
      print(string.format(
        " -> [Lane -> %s] %d ops (%dL) circuit=%s interface [%s] transposer [%s] item %d→%d fluid %d→%d",
        machine.id, target.operations, target.allocated_volume,
        tostring(lane_damage),
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

local function lane_id_set(lane_ids)
  local set = {}
  if type(lane_ids) ~= "table" then return set end
  for _, id in ipairs(lane_ids) do
    if type(id) == "string" and id ~= "" then set[id] = true end
  end
  return set
end

local function row_in_pool(row, pool)
  for _, m in ipairs(pool) do
    if m.id == row.id then return true end
  end
  return false
end

--- Pick config rows eligible for one multi job.
---@param auto_slice table[]|nil pre-partitioned rows when job omits lanes
local function resolve_job_pool(job, jobs, base_pool, claimed, only_idle, poll_results, auto_slice)
  local want = lane_id_set(job.lanes)
  local pool = {}

  if next(want) == nil then
    if auto_slice then
      for _, m in ipairs(auto_slice) do
        if not claimed[m.id] then pool[#pool + 1] = m end
      end
      return pool
    end
    if #jobs == 1 then
      for _, m in ipairs(base_pool) do
        if not claimed[m.id] then pool[#pool + 1] = m end
      end
      return pool
    end
    for _, m in ipairs(config.machines) do
      if not claimed[m.id] and row_in_pool(m, base_pool) then
        pool[#pool + 1] = m
      end
    end
    return pool
  end

  for _, m in ipairs(config.machines) do
    if want[m.id] and not claimed[m.id] and row_in_pool(m, base_pool) then
      pool[#pool + 1] = m
    elseif want[m.id] and only_idle then
      local st = poll_results and poll_results[m.id]
      if st and st.available and st.healthy and not MachinePoll.is_idle(st) then
        -- logged later via skipped_busy
      end
    end
  end
  return pool
end

--- Round-robin merge per-job lane queues for interleaved dispatch.
local function interleave_dispatches(buckets)
  local max_rounds = 0
  for _, bucket in ipairs(buckets) do
    if #bucket > max_rounds then max_rounds = #bucket end
  end
  local queue = {}
  for round = 1, max_rounds do
    for _, bucket in ipairs(buckets) do
      local entry = bucket[round]
      if entry then queue[#queue + 1] = entry end
    end
  end
  return queue
end

--- Split unclaimed idle lanes evenly across jobs that omit explicit lanes.
local function partition_auto_lanes(jobs, base_pool)
  local auto_indices = {}
  for ji, job in ipairs(jobs) do
    if next(lane_id_set(job.lanes)) == nil then
      auto_indices[#auto_indices + 1] = ji
    end
  end
  local slices = {}
  if #auto_indices <= 1 then return slices end

  local free = {}
  for _, m in ipairs(config.machines) do
    if row_in_pool(m, base_pool) then free[#free + 1] = m end
  end

  local n = #auto_indices
  local base = math.floor(#free / n)
  local remainder = #free % n
  local idx = 1
  for i, ji in ipairs(auto_indices) do
    local count = base + (i <= remainder and 1 or 0)
    slices[ji] = {}
    for _ = 1, count do
      if free[idx] then
        slices[ji][#slices[ji] + 1] = free[idx]
        idx = idx + 1
      end
    end
  end
  return slices
end

--- Multiple recipes in one call; interleaved across idle lanes by default.
---@param jobs table[] { recipe|recipe_key, volume, lanes? }
---@param opts table|nil
---@return boolean all_ok
---@return table summary
function BrokerCore.process_multi(jobs, opts)
  opts = opts or {}
  if type(jobs) ~= "table" or #jobs == 0 then
    return false, { dispatched = 0, succeeded = 0, failed = 0, jobs = {}, lanes = {}, err = "no jobs" }
  end

  local only_idle = opts.only_idle
  if only_idle == nil then only_idle = true end
  local interleave = opts.interleave
  if interleave == nil then interleave = true end

  print(string.format("\n[AutoOS] Subnet '%s' Initializing multi-recipe dispatch (%d job(s))...",
    config.subnet_id, #jobs))

  local poll = get_machine_poll(opts)
  local poll_results = opts.poll_results
  if not poll_results and poll then
    poll_results = poll:poll_all()
  end

  local base_pool
  if poll then
    base_pool = only_idle
      and poll:build_idle_pool(poll_results)
      or poll:build_active_pool(poll_results)
  else
    base_pool = config.machines
  end

  if #base_pool == 0 then
    local reason = only_idle and "no idle lanes" or "no healthy lanes"
    print("[Execution Halted] " .. reason)
    return false, { dispatched = 0, succeeded = 0, failed = 0, jobs = {}, lanes = {}, err = reason }
  end

  local claimed = {}
  local job_summaries = {}
  local buckets = {}
  local skipped_busy = {}
  local auto_slices = partition_auto_lanes(jobs, base_pool)

  for ji, job in ipairs(jobs) do
    local recipe_key = job.recipe or job.recipe_key
    local volume = job.volume
    if type(recipe_key) ~= "string" or type(volume) ~= "number" then
      job_summaries[#job_summaries + 1] = {
        index = ji, recipe = recipe_key, dispatched = 0, succeeded = 0, failed = 0,
        err = "invalid job (need recipe + volume)",
      }
    else
      local rules = recipe_rules(recipe_key)
      local js = {
        index = ji, recipe = recipe_key, dispatched = 0, succeeded = 0, failed = 0,
        total_ops = 0, lanes_assigned = {},
      }
      job_summaries[#job_summaries + 1] = js

      if not rules or not rules.fluid_requirement then
        js.err = "no recipe baseline"
        print(string.format("[AutoOS] Job %d '%s' skipped — unknown recipe", ji, recipe_key))
      else
        local want = lane_id_set(job.lanes)
        if poll_results and next(want) ~= nil and only_idle then
          for id in pairs(want) do
            local st = poll_results[id]
            if st and st.available and st.healthy and not MachinePoll.is_idle(st) then
              skipped_busy[#skipped_busy + 1] = id
              print(string.format(" -> [Pool] %s skipped — busy (active=%s has_work=%s)",
                id, tostring(st.active), tostring(st.has_work)))
            end
          end
        end

        local pool = resolve_job_pool(job, jobs, base_pool, claimed, only_idle, poll_results, auto_slices[ji])
        local total_ops = balancer.total_operations(volume, rules.fluid_requirement)
        js.total_ops = total_ops

        print(string.format(
          "[AutoOS] Job %d '%s' — %dL, %dL/op → %d ops, %d eligible lane(s)%s",
          ji, recipe_key, volume, rules.fluid_requirement, total_ops, #pool,
          only_idle and " (idle only)" or ""
        ))

        if total_ops < 1 then
          js.err = "volume too low"
        elseif #pool == 0 then
          js.err = "no eligible lanes"
        else
          local allocations, dist_err = balancer.calculate_distribution(pool, volume, rules.fluid_requirement)
          if not allocations then
            js.err = dist_err
            print(string.format("[AutoOS] Job %d halted: %s", ji, tostring(dist_err)))
          else
            local bucket = {}
            for _, machine in ipairs(pool) do
              local target = allocations[machine.id]
              if target and target.operations > 0 then
                claimed[machine.id] = true
                js.lanes_assigned[#js.lanes_assigned + 1] = machine.id
                bucket[#bucket + 1] = {
                  machine = machine,
                  target = target,
                  recipe_key = recipe_key,
                  job_index = ji,
                }
              end
            end
            buckets[#buckets + 1] = bucket
          end
        end
      end
    end
  end

  local queue
  if interleave then
    queue = interleave_dispatches(buckets)
  else
    queue = {}
    for _, bucket in ipairs(buckets) do
      for _, entry in ipairs(bucket) do queue[#queue + 1] = entry end
    end
  end

  local component = get_component(opts)
  local execute_hw = opts.execute_hardware
  if execute_hw == nil then execute_hw = component ~= nil end

  local summary = {
    dispatched = 0,
    succeeded = 0,
    failed = 0,
    jobs = job_summaries,
    lanes = {},
    skipped_busy = skipped_busy,
    order = {},
  }

  for _, entry in ipairs(queue) do
    local machine = entry.machine
    local target = entry.target
    local recipe_key = entry.recipe_key
    local ji = entry.job_index
    local js = job_summaries[ji]

    local iface_side, bus_side, fluid_pull, fluid_push = LaneSides.format_sides(machine)
    local lane_damage = circuit_damage_for(recipe_key, opts)
    print(string.format(
      " -> [Multi job %d -> %s] %d ops (%dL) recipe=%s circuit=%s item %d→%d fluid %d→%d",
      ji, machine.id, target.operations, target.allocated_volume, recipe_key,
      tostring(lane_damage), iface_side, bus_side, fluid_pull, fluid_push
    ))
    summary.order[#summary.order + 1] = { job = ji, lane = machine.id, recipe = recipe_key }

    if execute_hw and component then
      summary.dispatched = summary.dispatched + 1
      if js then js.dispatched = js.dispatched + 1 end

      local lane_opts = {}
      for k, v in pairs(opts) do lane_opts[k] = v end
      if lane_opts.recover_circuits == nil then
        lane_opts.recover_circuits = false
      end

      local ok_lane, lane_err = BrokerCore.execute_lane(machine, target, recipe_key, component, lane_opts)
      summary.lanes[machine.id] = {
        ok = ok_lane,
        err = lane_err,
        volume = target.allocated_volume,
        recipe = recipe_key,
        job = ji,
      }
      if ok_lane then
        summary.succeeded = summary.succeeded + 1
        if js then js.succeeded = js.succeeded + 1 end
        print(string.format(" -> [Multi job %d -> %s] Transfer complete (%dL)", ji, machine.id, target.allocated_volume))
      else
        summary.failed = summary.failed + 1
        if js then js.failed = js.failed + 1 end
        print(string.format(" -> [Multi job %d -> %s] Transfer FAILED: %s", ji, machine.id, tostring(lane_err)))
      end
    end
  end

  if summary.dispatched > 0 then
    print(string.format(
      "[AutoOS] Multi dispatch done: %d/%d lanes succeeded%s",
      summary.succeeded, summary.dispatched,
      summary.failed > 0 and (" — " .. summary.failed .. " FAILED (see above)") or ""
    ))
  elseif #queue == 0 then
    print("[AutoOS] Multi dispatch: nothing to run (all jobs skipped or 0 ops)")
  end

  return summary.failed == 0 and summary.dispatched > 0, summary
end

return BrokerCore
