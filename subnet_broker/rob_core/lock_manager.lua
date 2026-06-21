--[[
  AutoOS — LockManager
  Resource key building, two-phase acquire, release, early transport release.
]]
local C = require("rob_core.constants")

local LockManager = {}
LockManager.__index = LockManager

--- Create a new LockManager instance.
function LockManager.new()
  return setmetatable({
    _locks = {},  -- resource_key -> owner_machine_id
  }, LockManager)
end

--- Build resource keys for a machine's job.
--- @param machine table  machine config
--- @param shared_interface_address string|nil
--- @return table  array of resource key strings
function LockManager.build_resources(machine, shared_interface_address)
  local resources = {}

  local iface = machine.interface_address or shared_interface_address
  if iface and iface ~= "" then
    resources[#resources + 1] = C.RESOURCE_PREFIX_INTERFACE .. tostring(iface)
  end

  if machine.item_transposer_address then
    resources[#resources + 1] = C.RESOURCE_PREFIX_TP .. tostring(machine.item_transposer_address)
  end
  if machine.fluid_transposer_address then
    resources[#resources + 1] = C.RESOURCE_PREFIX_TP .. tostring(machine.fluid_transposer_address)
  end

  return resources
end

--- Two-phase acquire: check all, then acquire all.
--- @return boolean ok
--- @return string|nil err
function LockManager.acquire(self, machine_id, resources)
  -- Check first
  for _, res in ipairs(resources or {}) do
    local owner = self._locks[res]
    if owner and owner ~= machine_id then
      return false, "locked:" .. tostring(res) .. " by " .. tostring(owner)
    end
  end
  -- Acquire all
  for _, res in ipairs(resources or {}) do
    self._locks[res] = machine_id
  end
  return true
end

--- Release all locks held by a machine.
--- @param lane table|nil  lane record with locked_resources array
function LockManager.release(self, machine_id, lane)
  local resources = lane and lane.locked_resources
  if resources then
    for _, res in ipairs(resources) do
      if self._locks[res] == machine_id then
        self._locks[res] = nil
      end
    end
  end
  -- Belt-and-suspenders: scan for stale entries
  for res, owner in pairs(self._locks) do
    if owner == machine_id then self._locks[res] = nil end
  end
  if lane then
    lane.locked_resources = {}
  end
end

--- Early release of transport (tp:*) locks only.
--- Called by LaneWorker after Phase 4 stocking completes.
function LockManager.release_transport(self, machine_id, lane, log_fn)
  if not lane then return end

  -- Remove tp:* from global lock table
  for res, owner in pairs(self._locks) do
    if owner == machine_id and res:match("^tp:") then
      self._locks[res] = nil
    end
  end

  -- Trim tp:* from lane.locked_resources
  if lane.locked_resources then
    local kept = {}
    for _, res in ipairs(lane.locked_resources) do
      if not res:match("^tp:") then
        kept[#kept + 1] = res
      end
    end
    lane.locked_resources = kept
  end

  if log_fn then
    log_fn(string.format("[ROBDispatcher] %s released transport locks (stocking complete)", machine_id))
  end
end

--- Hard reset: release all locks for all lanes.
function LockManager.release_all(self, lanes)
  for _, lane in pairs(lanes or {}) do
    LockManager.release(self, nil, lane)
  end
  self._locks = {}
end

--- Return the internal locks table (read-only external access).
function LockManager.get_locks(self)
  return self._locks
end

return LockManager
