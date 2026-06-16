--[[
  AutoOS — Network protocols (orchestrator <-> broker <-> broadcast)

  Pure string codec for pipe-delimited modem messages. No hardware, no state —
  safe to require on either OC and in desktop tests.

  Message kinds (field order matters):
    BROKER_HEALTH|subnet_id|machine_id|state|detail
    BROKER_EVENT |subnet_id|event|label|volume|job_id
    (legacy/compat) DISPATCH_JOB / SUBNET_DELIVERY / BROKER_STATUS / CRAFT_*

  Deploy: copy this file into BOTH /home/orchestrator and /home/subnet_broker
  (each OC requires it locally as "network_protocols").
]]

local Protocols = {}

Protocols.PORT_DEFAULT = 105

Protocols.KIND = {
  BROKER_HEALTH = "BROKER_HEALTH",
  DISPATCH_JOB = "DISPATCH_JOB",
  BROKER_STATUS = "BROKER_STATUS",
  BROKER_EVENT = "BROKER_EVENT",
  CRAFT_ACK = "CRAFT_ACK",
  CRAFT_DONE = "CRAFT_DONE",
  CRAFT_FAIL = "CRAFT_FAIL",
  TRIGGER_CRAFT = "TRIGGER_CRAFT",
  SUBNET_DELIVERY = "SUBNET_DELIVERY",
  DELIVERY_ACK = "DELIVERY_ACK",
}

Protocols.PHASE = {
  DISPATCHING = "dispatching",
  RUNNING = "running",
  RECOVERING = "recovering",
  COMPLETE = "complete",
  FAILED = "failed",
}

Protocols.EVENT = {
  AE_CRAFT_START = "ae_craft_start",
  DISPATCH_START = "dispatch_start",
  JOB_COMPLETE = "job_complete",
  JOB_FAILED = "job_failed",
  CIRCUIT_RECOVERED = "circuit_recovered",
  CIRCUIT_RECOVER_FAILED = "circuit_recover_failed",
  MACHINE_FAULT = "machine_fault",
}

Protocols.MODE = { BATCH = "batch", MULTI = "multi" }

--- Replace field separators so a stray "|" can never corrupt a message.
local function clean(v)
  return (tostring(v == nil and "" or v):gsub("|", "/"))
end

local function num(v)
  return tostring(math.floor(tonumber(v) or 0))
end

--- Split a wire string into its pipe-delimited fields.
---@param message string
---@return string[]
local function split(message)
  local parts = {}
  for field in (message .. "|"):gmatch("([^|]*)|") do
    parts[#parts + 1] = field
  end
  return parts
end

-- Encoders --------------------------------------------------------------------

function Protocols.broker_health(subnet_id, machine_id, state, detail)
  return table.concat({
    Protocols.KIND.BROKER_HEALTH, clean(subnet_id), clean(machine_id), clean(state), clean(detail),
  }, "|")
end

function Protocols.dispatch_job(job_id, recipe_uid, recipe_key, volume_mB, subnet_id, mode)
  return table.concat({
    Protocols.KIND.DISPATCH_JOB, clean(job_id), num(recipe_uid), clean(recipe_key),
    num(volume_mB), clean(subnet_id), clean(mode or Protocols.MODE.BATCH),
  }, "|")
end

function Protocols.broker_status(subnet_id, job_id, phase, detail)
  return table.concat({
    Protocols.KIND.BROKER_STATUS, clean(subnet_id), clean(job_id), clean(phase), clean(detail),
  }, "|")
end

function Protocols.broker_event(subnet_id, event, label, volume, job_id)
  return table.concat({
    Protocols.KIND.BROKER_EVENT, clean(subnet_id), clean(event), clean(label),
    num(volume), clean(job_id),
  }, "|")
end

function Protocols.craft_ack(job_id, subnet_id)
  return table.concat({ Protocols.KIND.CRAFT_ACK, clean(job_id), clean(subnet_id) }, "|")
end

function Protocols.craft_done(job_id, subnet_id)
  return table.concat({ Protocols.KIND.CRAFT_DONE, clean(job_id), clean(subnet_id) }, "|")
end

function Protocols.craft_fail(job_id, subnet_id, detail)
  return table.concat({ Protocols.KIND.CRAFT_FAIL, clean(job_id), clean(subnet_id), clean(detail) }, "|")
end

function Protocols.trigger_craft(job_id, me_label, volume_mB, subnet_id)
  return table.concat({
    Protocols.KIND.TRIGGER_CRAFT, clean(job_id), clean(me_label), num(volume_mB), clean(subnet_id),
  }, "|")
end

function Protocols.subnet_delivery(subnet_id, job_id, recipe_uid, recipe_key, volume_mB, source)
  return table.concat({
    Protocols.KIND.SUBNET_DELIVERY, clean(subnet_id), clean(job_id), num(recipe_uid),
    clean(recipe_key), num(volume_mB), clean(source or ""),
  }, "|")
end

function Protocols.delivery_ack(job_id, subnet_id)
  return table.concat({ Protocols.KIND.DELIVERY_ACK, clean(job_id), clean(subnet_id) }, "|")
end

-- Decoder ---------------------------------------------------------------------

--- Parse a wire string into a structured table keyed by `kind`.
---@param message any
---@return table|nil packet, string|nil err
function Protocols.parse(message)
  if type(message) ~= "string" or message == "" then
    return nil, "not a string message"
  end
  local p = split(message)
  local kind = p[1]
  local K = Protocols.KIND

  if kind == K.BROKER_HEALTH then
    return {
      kind = kind, subnet_id = p[2], machine_id = p[3], state = p[4], detail = p[5],
    }
  elseif kind == K.DISPATCH_JOB then
    return {
      kind = kind, job_id = p[2], recipe_uid = tonumber(p[3]),
      recipe_key = p[4], volume_mB = tonumber(p[5]) or 0,
      subnet_id = p[6], mode = p[7] ~= "" and p[7] or Protocols.MODE.BATCH,
    }
  elseif kind == K.BROKER_STATUS then
    return { kind = kind, subnet_id = p[2], job_id = p[3], phase = p[4], detail = p[5] }
  elseif kind == K.BROKER_EVENT then
    return {
      kind = kind, subnet_id = p[2], event = p[3], label = p[4],
      volume = tonumber(p[5]) or 0, job_id = p[6],
    }
  elseif kind == K.CRAFT_ACK or kind == K.CRAFT_DONE then
    return { kind = kind, job_id = p[2], subnet_id = p[3] }
  elseif kind == K.CRAFT_FAIL then
    return { kind = kind, job_id = p[2], subnet_id = p[3], detail = p[4] }
  elseif kind == K.TRIGGER_CRAFT then
    return {
      kind = kind, job_id = p[2], me_label = p[3],
      volume_mB = tonumber(p[4]) or 0, subnet_id = p[5],
    }
  elseif kind == K.SUBNET_DELIVERY then
    return {
      kind = kind, subnet_id = p[2], job_id = p[3], recipe_uid = tonumber(p[4]),
      recipe_key = p[5], volume_mB = tonumber(p[6]) or 0, source = p[7],
    }
  elseif kind == K.DELIVERY_ACK then
    return { kind = kind, job_id = p[2], subnet_id = p[3] }
  end
  return nil, "unknown message kind: " .. tostring(kind)
end

return Protocols
