--[[
  AutoOS — Shared OC hardware helpers (subnet broker)

  Single home for component proxy / network checks / sleep so the other
  modules stop carrying their own copies.
]]

local HW = {}

--- Sleep that works on OpenOS and desktop Lua (no-op without os.sleep).
---@param seconds number
function HW.sleep(seconds)
  if os and os.sleep then os.sleep(seconds) end
end

--- Proxy an address, trying the typed call first then untyped.
---@param component table OC component API
---@param address string
---@param hint string|nil component type hint
---@return table|nil proxy
---@return string|nil err
function HW.proxy(component, address, hint)
  if not component or not component.proxy then
    return nil, "component API unavailable"
  end
  local ok, p = pcall(component.proxy, address, hint)
  if ok and p then return p end
  local err = not ok and p or nil
  ok, p = pcall(component.proxy, address)
  if ok and p then return p end
  return nil, tostring(err or p or "proxy returned nil")
end

--- True when the address is visible on the OC network.
---@param component table
---@param address string
---@return boolean
function HW.on_network(component, address)
  if not component or not component.list then return false end
  local list = component.list()
  return list[address] ~= nil
end

--- Proxy with a clear, actionable error message.
---@param component table
---@param label string human name used in errors ("me_interface", "transposer", ...)
---@param address string
---@param hint string|nil
---@return table|nil proxy
---@return string|nil err
function HW.require_proxy(component, label, address, hint)
  if not address or address == "" then
    return nil, label .. " address not configured"
  end
  if not HW.on_network(component, address) then
    return nil, string.format(
      "%s address %q not on OC network (run component.list())",
      label, tostring(address)
    )
  end
  local p, err = HW.proxy(component, address, hint)
  if not p then
    return nil, string.format("%s proxy failed at %q: %s", label, tostring(address), tostring(err))
  end
  return p
end

return HW
