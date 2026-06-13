--[[
  AutoOS — Main net ME cache (orchestrator's ME proxy)

  The orchestrator OC sits on the MAIN AE2 network (not the subnet). One
  filtered poll per tick:
    * craft-token items grouped by damage (= recipe_uid)
    * circuit items grouped by damage (= circuit_damage)  [fallback only]
    * fluids grouped by label (mB)

  poll() returns positive deltas since the previous snapshot — what just
  landed on the main net. Patterns that export into the subnet may not show
  here; use main_net_craft job completion to dispatch in that case.

  References: CommonNetworkAPI.getItemsInNetwork / getFluidsInNetwork
]]

local HW = require("hw")

local MainNetCache = {}
MainNetCache.__index = MainNetCache

function MainNetCache.new(deps)
  deps = deps or {}
  local cfg = deps.config or error("MainNetCache.new: config required")
  local o = cfg.orchestrator or {}
  local self = setmetatable({}, MainNetCache)
  self.config = cfg
  self.component = deps.component
  self.me = deps.me
  self.me_address = deps.me_address or cfg.me_address
  self.token_item = o.token_item_name or "gregtech:gt.integrated_circuit"
  self.circuit_item = o.circuit_item_name or self.token_item
  self.last = nil
  return self
end

function MainNetCache:_proxy()
  if self.me then return self.me end
  if not self.component then return nil end
  local p = HW.require_proxy(self.component, "main_net_me", self.me_address, nil)
  self.me = p
  return p
end

local function count_by_damage(me, name)
  local out = {}
  if not me or not me.getItemsInNetwork then return out end
  local stacks = me.getItemsInNetwork({ name = name })
  if type(stacks) ~= "table" then return out end
  for _, it in ipairs(stacks) do
    local dmg = it.damage or 0
    out[dmg] = (out[dmg] or 0) + (it.size or 0)
  end
  return out
end

local function fluids_by_label(me)
  local out = {}
  if not me or not me.getFluidsInNetwork then return out end
  local fluids = me.getFluidsInNetwork()
  if type(fluids) ~= "table" then return out end
  for _, fl in ipairs(fluids) do
    if fl.label then out[fl.label] = (out[fl.label] or 0) + (fl.amount or 0) end
  end
  return out
end

function MainNetCache:snapshot()
  local me = self:_proxy()
  local snap = {
    tokens = count_by_damage(me, self.token_item),
    fluids = fluids_by_label(me),
  }
  if self.circuit_item ~= self.token_item then
    snap.circuits = count_by_damage(me, self.circuit_item)
  else
    snap.circuits = snap.tokens
  end
  return snap
end

local function positive_delta(current, previous)
  local out = {}
  for key, now in pairs(current or {}) do
    local was = (previous or {})[key] or 0
    if now > was then out[key] = now - was end
  end
  return out
end

function MainNetCache:poll()
  local snap = self:snapshot()
  local prev = self.last
  self.last = snap
  if prev == nil then
    return { tokens = {}, circuits = {}, fluids = {}, seeded = true }
  end
  return {
    tokens = positive_delta(snap.tokens, prev.tokens),
    circuits = positive_delta(snap.circuits, prev.circuits),
    fluids = positive_delta(snap.fluids, prev.fluids),
  }
end

function MainNetCache:reset()
  self.last = nil
end

return MainNetCache
