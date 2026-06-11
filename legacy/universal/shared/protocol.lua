--[[
  Universal Craft Brokers — modem protocol (pipe-delimited strings only).

  OC modem payloads: nil, boolean, number, string — no tables.
  Port default: 4410 (configured in start.lua).
]]

local Protocol = {}

local RESERVED = {
  capability_advertise = true,
}

function Protocol.encode(msg_type, ...)
  local parts = { tostring(msg_type) }
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  return table.concat(parts, "|")
end

-- Returns { type = string, fields = string[] } or nil.
function Protocol.decode(payload)
  if type(payload) ~= "string" or payload == "" then
    return nil
  end
  local fields = {}
  for part in payload:gmatch("[^|]+") do
    fields[#fields + 1] = part
  end
  if #fields == 0 then
    return nil
  end
  return { type = fields[1], fields = fields }
end

function Protocol.is_reserved(msg_type)
  return RESERVED[msg_type] == true
end

function Protocol.craft_req(job_id, label, amount, kind)
  return Protocol.encode("craft_req", job_id, label, amount, kind or "item")
end

function Protocol.parse_craft_req(fields)
  if not fields or fields[1] ~= "craft_req" or #fields < 5 then
    return nil
  end
  return {
    job_id = fields[2],
    label = fields[3],
    amount = tonumber(fields[4]) or 0,
    kind = fields[5] or "item",
  }
end

function Protocol.craft_ack(job_id, machine_id, broker_id)
  return Protocol.encode("craft_ack", job_id, machine_id, broker_id)
end

function Protocol.parse_craft_ack(fields)
  if not fields or fields[1] ~= "craft_ack" or #fields < 4 then
    return nil
  end
  return {
    job_id = fields[2],
    machine_id = fields[3],
    broker_id = fields[4],
  }
end

function Protocol.craft_done(job_id, machine_id)
  return Protocol.encode("craft_done", job_id, machine_id)
end

function Protocol.parse_craft_done(fields)
  if not fields or fields[1] ~= "craft_done" or #fields < 3 then
    return nil
  end
  return { job_id = fields[2], machine_id = fields[3] }
end

function Protocol.craft_fail(job_id, reason)
  return Protocol.encode("craft_fail", job_id, reason or "unknown")
end

function Protocol.parse_craft_fail(fields)
  if not fields or fields[1] ~= "craft_fail" or #fields < 3 then
    return nil
  end
  return { job_id = fields[2], reason = fields[3] }
end

function Protocol.ping(coordinator_id)
  return Protocol.encode("ping", coordinator_id or "coordinator")
end

function Protocol.pong(broker_id)
  return Protocol.encode("pong", broker_id)
end

-- Reserved for future discovery (v1: decode only).
function Protocol.capability_advertise(broker_id, caps_csv)
  return Protocol.encode("capability_advertise", broker_id, caps_csv)
end

function Protocol.parse_capability_advertise(fields)
  if not fields or fields[1] ~= "capability_advertise" or #fields < 3 then
    return nil
  end
  local caps = {}
  for cap in fields[3]:gmatch("[^,]+") do
    caps[#caps + 1] = cap
  end
  return { broker_id = fields[2], capabilities = caps }
end

return Protocol
