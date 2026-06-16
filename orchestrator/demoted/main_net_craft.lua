--[[
  AutoOS — Main net AE crafting helper

  Thin wrapper over CommonNetworkAPI.getCraftables / AECraftable.request on the
  MAIN network. getCraftables is only called on demand, never every tick.

  References: AECraftable.lua, AECraftingJob.lua
]]

local MainNetCraft = {}

local function as_list(craftables)
  if type(craftables) ~= "table" then return {} end
  if craftables.getItemStack or craftables.request then return { craftables } end
  return craftables
end

---@param me table main net ME proxy
function MainNetCraft.craftable(me, label)
  if not me or not me.getCraftables then return nil end
  local ok, list = pcall(me.getCraftables, { label = label })
  if not ok then return nil end
  for _, c in ipairs(as_list(list)) do
    local stack = c.getItemStack and c.getItemStack()
    if not stack or stack.label == label or stack.label == nil then
      return c
    end
  end
  return nil
end

function MainNetCraft.is_craftable(me, label)
  return MainNetCraft.craftable(me, label) ~= nil
end

--- Issue a craft on the main net. Returns AECraftingJob tracker or nil, err.
function MainNetCraft.request(me, label, amount, cpu)
  local c = MainNetCraft.craftable(me, label)
  if not c then return nil, "no craftable pattern for " .. tostring(label) end
  if not c.request then return nil, "craftable missing request()" end
  local ok, job = pcall(c.request, amount, false, cpu)
  if not ok or not job then return nil, "request failed: " .. tostring(job) end
  return job
end

---@return string phase  computing | failed | canceled | done | running | none
function MainNetCraft.job_phase(job)
  if not job then return "none" end
  if job.isComputing and job.isComputing() then return "computing" end
  if job.hasFailed and job.hasFailed() then return "failed" end
  if job.isCanceled and job.isCanceled() then return "canceled" end
  if job.isDone and job.isDone() then return "done" end
  return "running"
end

return MainNetCraft
