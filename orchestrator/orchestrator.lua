--[[
  AutoOS — Orchestrator FSM (no lane hardware)

  The orchestrator OC lives on the MAIN net. It watches main ME storage
  (main_net_cache), requests crafts on the main net (main_net_craft), and
  tells the subnet broker when to run machines.

  Two ways to decide "go run the machines":
    1. Something new showed up on the main net (fluid + recipe tag) — delta poll
    2. A main-net craft we asked for just finished — then dispatch that volume
       (patterns that export straight to the subnet often use this path)

  Injected deps: config, registry, main_net_cache, craft_resolver, main_net_craft,
  link, me (main net proxy), now(), log().
]]

local Protocols = require("network_protocols")
local CraftResolver = require("craft_resolver")
local MainNetCraft = require("main_net_craft")

local Orchestrator = {}
Orchestrator.__index = Orchestrator

function Orchestrator.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Orchestrator)
  self.config = deps.config or error("Orchestrator.new: config required")
  self.registry = deps.registry or error("Orchestrator.new: registry required")
  self.main_net_cache = deps.main_net_cache or error("Orchestrator.new: main_net_cache required")
  self.craft_resolver = deps.craft_resolver or CraftResolver
  self.main_net_craft = deps.main_net_craft or MainNetCraft
  self.link = deps.link or error("Orchestrator.new: link required")
  self.me = deps.me
  self.now = deps.now or function() return 0 end
  self._log = deps.log or function() end

  local cfg = self.config
  local o = cfg.orchestrator or {}
  self.subnet_id = cfg.subnet_id
  self.broker_address = (cfg.broker_address ~= "" and cfg.broker_address) or nil
  self.min_dispatch = o.min_dispatch_mB
  self.dispatch_on_craft_done = o.dispatch_on_craft_done ~= false

  self.state = "idle"
  self.current_job = nil
  self.pending_craft = nil   -- { row, volume_mB, job } after main-net AE request
  self._seq = 0
  return self
end

function Orchestrator:log(msg)
  self._log("[Orchestrator] " .. msg)
end

function Orchestrator:_next_job_id()
  self._seq = self._seq + 1
  return string.format("%s-%d", self.subnet_id, self._seq)
end

function Orchestrator:_dispatch(row, volume_mB)
  if not self.broker_address then
    self:log("cannot dispatch — set broker_address or wait for broker to reply first")
    return false
  end
  local job_id = self:_next_job_id()
  self.link:send(self.broker_address, Protocols.dispatch_job(
    job_id, row.recipe_uid, row.recipe_key, volume_mB, self.subnet_id, Protocols.MODE.BATCH
  ))
  self.link:broadcast(Protocols.broker_event(
    self.subnet_id, Protocols.EVENT.DISPATCH_START, row.display_name, volume_mB, job_id
  ))
  self.current_job = {
    job_id = job_id, recipe_key = row.recipe_key, recipe_uid = row.recipe_uid,
    display_name = row.display_name, volume_mB = volume_mB, acked = false, started = self:now(),
  }
  self.state = "waiting_broker"
  self:log(string.format("DISPATCH_JOB %s uid=%d %s %dmB", job_id, row.recipe_uid, row.recipe_key, volume_mB))
  return true
end

--- If we are waiting on a main-net craft to finish, dispatch when it is done.
function Orchestrator:_tick_pending_craft()
  local pending = self.pending_craft
  if not pending or not self.dispatch_on_craft_done then return end

  local phase = self.main_net_craft.job_phase(pending.job)
  if phase == "done" then
    self.pending_craft = nil
    self:log("main-net craft done — dispatching " .. pending.row.recipe_key)
    self:_dispatch(pending.row, pending.volume_mB)
  elseif phase == "failed" or phase == "canceled" then
    self:log("main-net craft " .. phase .. " for " .. pending.row.recipe_key)
    self.pending_craft = nil
  end
end

function Orchestrator:tick()
  if self.current_job then
    return self.state
  end

  self:_tick_pending_craft()
  if self.current_job then return self.state end

  local deltas = self.main_net_cache:poll()
  if deltas.seeded then return self.state end

  local res = self.craft_resolver.resolve(deltas, self.registry)
  if res.fault then
    self:log("FAULT " .. tostring(res.reason))
    return self.state
  end
  if not res.matched then return self.state end

  self.registry:confirm_uid(res.recipe_uid, self:now())
  if res.volume_mB <= 0 then return self.state end
  if self.min_dispatch and res.volume_mB < self.min_dispatch then return self.state end

  self:_dispatch(res.row, res.volume_mB)
  return self.state
end

function Orchestrator:on_message(from, message)
  local pkt = Protocols.parse(message)
  if not pkt then return end
  local K = Protocols.KIND

  if pkt.kind == K.BROKER_STATUS then
    if not self.broker_address and from then self.broker_address = from end
    self:_on_status(pkt)
  elseif pkt.kind == K.CRAFT_ACK then
    if self.current_job and self.current_job.job_id == pkt.job_id then
      self.current_job.acked = true
    end
  elseif pkt.kind == K.TRIGGER_CRAFT then
    self:_on_trigger(pkt)
  end
end

function Orchestrator:_on_status(pkt)
  local job = self.current_job
  if not job or job.job_id ~= pkt.job_id then return end
  if pkt.phase == Protocols.PHASE.COMPLETE then
    self.link:broadcast(Protocols.broker_event(
      self.subnet_id, Protocols.EVENT.JOB_COMPLETE, job.display_name, 0, job.job_id
    ))
    self:log("job complete: " .. job.job_id)
    self.current_job = nil
    self.state = "idle"
  elseif pkt.phase == Protocols.PHASE.FAILED then
    self.link:broadcast(Protocols.broker_event(
      self.subnet_id, Protocols.EVENT.JOB_FAILED, job.display_name, 0, job.job_id
    ))
    self:log("job FAILED: " .. job.job_id .. " — " .. tostring(pkt.detail))
    self.current_job = nil
    self.state = "idle"
  end
end

function Orchestrator:_on_trigger(pkt)
  local row = self.registry:lookup_label(pkt.me_label)
  if not row then
    self:log("TRIGGER_CRAFT for unknown label " .. tostring(pkt.me_label))
    return
  end
  local volume_mB = pkt.volume_mB or 0
  self.link:broadcast(Protocols.broker_event(
    self.subnet_id, Protocols.EVENT.AE_CRAFT_START, row.display_name, volume_mB, pkt.job_id
  ))

  if not self.me then
    self:log("AE craft requested (no ME proxy) for " .. row.display_name)
    return
  end

  local amount = math.max(1, math.floor(volume_mB / (row.fluid_requirement or 1)))
  local job, err = self.main_net_craft.request(self.me, row.fluid_label, amount)
  if not job then
    self:log("AE craft request failed: " .. tostring(err))
    return
  end

  self.pending_craft = { row = row, volume_mB = volume_mB, job = job }
  self:log(string.format("main-net craft started for %s (%dmB)", row.display_name, volume_mB))
end

return Orchestrator
