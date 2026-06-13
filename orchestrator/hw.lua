--[[
  AutoOS — OC hardware helpers (orchestrator deploy copy)

  Same module as subnet_broker/hw.lua — kept here so the orchestrator PC
  only needs files under /home/orchestrator/ (no broker folder required).
]]

local HW = {}

function HW.sleep(seconds)
  if os and os.sleep then os.sleep(seconds) end
end

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

function HW.on_network(component, address)
  if not component or not component.list then return false end
  local list = component.list()
  return list[address] ~= nil
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
