--[[
  AutoOS — Shared OC hardware helpers (subnet broker)

  Single home for component proxy / network checks / sleep so the other
  modules stop carrying their own copies.
]]

local HW = {}
local proxy_cache = {}

local function proxy_cache_key(component, address)
  return tostring(component) .. ":" .. tostring(address)
end

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
  if not address or address == "" then
    return nil, "component address not configured"
  end
  local cache_key = proxy_cache_key(component, address)
  if proxy_cache[cache_key] then
    return proxy_cache[cache_key]
  end
  local ok, p = pcall(component.proxy, address, hint)
  if ok and p then
    proxy_cache[cache_key] = p
    return p
  end
  local err = not ok and p or nil
  ok, p = pcall(component.proxy, address)
  if ok and p then
    proxy_cache[cache_key] = p
    return p
  end
  return nil, tostring(err or p or "proxy returned nil")
end

function HW.clear_proxy_cache(address)
  if address then
    proxy_cache[address] = nil
  else
    proxy_cache = {}
  end
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
--- Bulk read all stacks from a transposer/inventory_controller side.
--- Replaces getInventorySize + N x getStackInSlot with a single call.
--- getAllStacks returns userdata; indexable by slot number [1..N].
--- Returns a plain table {[slot] = stack_table, ...} for safe iteration.
--- Falls back to manual scan if getAllStacks is unavailable.
function HW.get_all_stacks(proxy, side)
  if not proxy or not side then return {} end
  if proxy.getAllStacks then
    local ok, stacks = pcall(proxy.getAllStacks, side)
    if ok and type(stacks) == "userdata" then
      local size = 0
      if proxy.getInventorySize then
        local ok_sz, n = pcall(proxy.getInventorySize, side)
        if ok_sz and type(n) == "number" then size = n end
      end
      if size <= 0 then size = 64 end  -- fallback: inventory_controller may report 0
      local out = {}
      for slot = 1, size do
        local stack = stacks[slot]
        if type(stack) == "table" and (stack.size or 0) > 0 then
          out[slot] = stack
        end
      end
      return out
    end
  end
  -- Fallback: manual slot scan
  local out = {}
  local size = 0
  if proxy.getInventorySize then
    local ok, n = pcall(proxy.getInventorySize, side)
    if ok and type(n) == "number" then size = n end
  end
  if size <= 0 then return out end
  for slot = 1, size do
    local ok, stack = pcall(proxy.getStackInSlot, side, slot)
    if ok and type(stack) == "table" and (stack.size or 0) > 0 then
      out[slot] = stack
    end
  end
  return out
end

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
