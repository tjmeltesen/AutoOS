--[[
  Universal Craft Brokers — broker-side hardware poll (machines only).
]]

local Maintenance = require("modules.maintenance")

local Adapter = {}
Adapter.__index = Adapter

function Adapter.new(registry)
  return setmetatable({ registry = registry }, Adapter)
end

function Adapter:poll(cache)
  cache.machines = cache.machines or {}
  for _, multi in ipairs(self.registry:list()) do
    local proxy = self.registry:get_proxy(multi.id)
    local entry = cache.machines[multi.id] or {}
    cache.machines[multi.id] = entry

    if not proxy then
      entry.available = false
    else
      entry.available = true
      entry.work_allowed = proxy.isWorkAllowed and proxy.isWorkAllowed() or nil
      entry.active = proxy.isMachineActive and proxy.isMachineActive() or false
      entry.has_work = proxy.hasWork and proxy.hasWork() or false
      local sensor = proxy.getSensorInformation and proxy.getSensorInformation() or {}
      entry.sensor = sensor
      local faulted = Maintenance.has_fault(sensor)
      entry.maintenance_fault = faulted
    end
  end
  return cache
end

return Adapter
