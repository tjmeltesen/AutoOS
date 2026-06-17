--[[
  AutoOS — Machine Poll (Phase 2)

  Polls gt_machine proxies for maintenance faults and builds the healthy active pool.

  References: references/gtnh-opencomputers-overview.md, maintenance_parse.lua
]]

local MaintenanceParse = require("maintenance_parse")
local HW = require("hw")

local MachinePoll = {}
MachinePoll.__index = MachinePoll

function MachinePoll.new(deps)
  deps = deps or {}
  local self = setmetatable({}, MachinePoll)
  self.config = deps.config or error("MachinePoll.new: config required")
  self.component = deps.component
  self.proxies = {}
  self.proxy_errors = {}

  if self.component and self.component.proxy then
    for _, machine in ipairs(self.config.machines) do
      local proxy, err = HW.require_proxy(
        self.component, "gt_machine", machine.gt_address, "gt_machine")
      if proxy then
        self.proxies[machine.id] = proxy
      else
        self.proxy_errors[machine.id] = err
      end
    end
  end

  return self
end

function MachinePoll:get_proxy(machine_id)
  return self.proxies[machine_id]
end

function MachinePoll:poll_machine(machine_row)
  local status = {
    id = machine_row.id,
    available = false,
    healthy = false,
    maintenance_fault = false,
    fault_message = nil,
    work_allowed = nil,
    active = false,
    has_work = false,
    work_progress = 0,
    work_max_progress = 0,
    sensor = {},
  }

  local proxy = self.proxies[machine_row.id]
  if not proxy then
    status.fault_message = self.proxy_errors[machine_row.id]
      or "gt_machine proxy unavailable"
    return status
  end

  status.available = true

  if proxy.isWorkAllowed then
    status.work_allowed = proxy.isWorkAllowed()
  end
  if proxy.isMachineActive then
    status.active = proxy.isMachineActive() or false
  end
  if proxy.hasWork then
    status.has_work = proxy.hasWork() or false
  end
  if proxy.getWorkProgress then
    status.work_progress = proxy.getWorkProgress() or 0
  end
  if proxy.getWorkMaxProgress then
    status.work_max_progress = proxy.getWorkMaxProgress() or 0
  end

  local sensor = proxy.getSensorInformation and proxy.getSensorInformation() or {}
  status.sensor = sensor

  local faulted, message = MaintenanceParse.has_fault(sensor)
  status.maintenance_fault = faulted
  status.fault_message = message
  status.healthy = not faulted

  return status
end

function MachinePoll:poll_all()
  local results = {}
  for _, machine in ipairs(self.config.machines) do
    results[machine.id] = self:poll_machine(machine)
  end
  return results
end

function MachinePoll:build_active_pool(poll_results)
  poll_results = poll_results or self:poll_all()
  local pool = {}
  for _, machine in ipairs(self.config.machines) do
    local st = poll_results[machine.id]
    if st and st.healthy then
      pool[#pool + 1] = machine
    end
  end
  return pool
end

--- Lane is idle when healthy, proxy available, and not actively crafting.
---@param status table poll result for one machine
---@return boolean
function MachinePoll.is_idle(status)
  if not status or not status.available or not status.healthy then
    return false
  end
  if status.active then return false end
  if status.has_work then return false end
  return true
end

--- Healthy lanes that are not currently running a recipe (free for dispatch).
---@param poll_results table|nil
---@return table[] pool of machine config rows
function MachinePoll:build_idle_pool(poll_results)
  poll_results = poll_results or self:poll_all()
  local pool = {}
  for _, machine in ipairs(self.config.machines) do
    local st = poll_results[machine.id]
    if MachinePoll.is_idle(st) then
      pool[#pool + 1] = machine
    end
  end
  return pool
end

return MachinePoll
