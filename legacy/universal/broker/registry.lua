--[[
  Universal Craft Brokers — broker registry validation and machine proxy binding.
]]

local Registry = {}
Registry.__index = Registry

function Registry.new(config, component_lib)
  config = config or {}
  assert(config.broker_id, "Registry.new: broker_id required")

  local self = setmetatable({}, Registry)
  self.broker_id = config.broker_id
  self.multis = {}
  self.proxies = {}

  for _, multi in ipairs(config.multis or {}) do
    Registry._validate_multi(multi)
    self.multis[#self.multis + 1] = multi
    if component_lib and multi.address then
      local ok, proxy = pcall(component_lib.proxy, multi.address, "gt_machine")
      if ok and proxy then
        self.proxies[multi.id] = proxy
      end
    end
  end

  return self
end

function Registry._validate_multi(multi)
  assert(multi.id, "multi entry requires id")
  assert(type(multi.capabilities) == "table" and #multi.capabilities > 0,
    "multi " .. tostring(multi.id) .. " requires capabilities[]")
end

function Registry:get_proxy(machine_id)
  return self.proxies[machine_id]
end

function Registry:list()
  return self.multis
end

return Registry
