--[[
  AutoOS — OC component API mock
  Models: component.list(), component.type(), component.proxy(), component.isAvailable()

  Usage:
    local mock_component = OCComponentMock.new({
      components = { ["uuid-1"] = "gt_machine", ["uuid-2"] = "transposer" },
    })
    local proxy = mock_component.proxy("uuid-1")  -- returns mock proxy object
    local types = mock_component.list("gt_machine") -- returns { ["uuid-1"] = "gt_machine" }
]]

local OCComponentMock = {}

function OCComponentMock.new(opts)
  opts = opts or {}
  local components = opts.components or {}
  local proxies = opts.proxies or {}  -- address -> pre-built proxy object

  local self = {
    _components = components,
    _proxies = proxies,
    _call_counts = { list = 0, type = 0, proxy = 0, isAvailable = 0 },
  }
  setmetatable(self, { __index = OCComponentMock })
  return self
end

--- component.list(filter?) -> { [address] = type_name }
function OCComponentMock.list(self, filter)
  self._call_counts.list = self._call_counts.list + 1
  if not filter then
    local cp = {}
    for addr, t in pairs(self._components) do
      cp[addr] = t
    end
    return cp
  end
  local cp = {}
  for addr, t in pairs(self._components) do
    if t == filter then cp[addr] = t end
  end
  return cp
end

--- component.type(address) -> type_name | nil
function OCComponentMock.type(self, address)
  self._call_counts.type = self._call_counts.type + 1
  return self._components[address]
end

--- component.proxy(address, hint?) -> proxy object | nil, error
function OCComponentMock.proxy(self, address, hint)
  self._call_counts.proxy = self._call_counts.proxy + 1
  if self._proxies[address] then
    return self._proxies[address]
  end
  if self._components[address] then
    return nil, "no proxy configured for " .. address .. " (type: " .. self._components[address] .. ")"
  end
  return nil, "no component at " .. address
end

--- component.isAvailable(type_name) -> boolean
function OCComponentMock.isAvailable(self, type_name)
  self._call_counts.isAvailable = self._call_counts.isAvailable + 1
  for _, t in pairs(self._components) do
    if t == type_name then return true end
  end
  return false
end

--- Mutations for test control
function OCComponentMock.add_component(self, address, type_name)
  self._components[address] = type_name
end

function OCComponentMock.remove_component(self, address)
  self._components[address] = nil
  self._proxies[address] = nil
end

function OCComponentMock.set_proxy(self, address, proxy)
  self._proxies[address] = proxy
end

function OCComponentMock.get_call_counts(self)
  return self._call_counts
end

return OCComponentMock
