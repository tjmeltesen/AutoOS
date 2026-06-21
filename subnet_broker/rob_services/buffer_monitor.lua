--[[
  AutoOS — Buffer Monitor State Machine
  fingerprint → stabilize → manifest → enqueue FSM.
  Injected dependencies for testability (no direct registry/config access).
]]
local C = require("rob_core.constants")

local BufferMonitor = {}

-- Pure helpers (module-level, no state)
local function fingerprint_equal(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  for slot, n in pairs(a) do
    if b[slot] ~= n then return false end
  end
  for slot, n in pairs(b) do
    if a[slot] ~= n then return false end
  end
  return true
end

local function fingerprint_nonempty(fp)
  return fp and next(fp) ~= nil
end

--- Create a new BufferMonitor instance.
--- @return table
function BufferMonitor.new()
  return {
    _state = C.DIS_IDLE,
    _fingerprint = nil,
    _stable_since = 0,
    _last_enqueued_fp = nil,
    _batch_claimed = false,
    _batch_job_id = nil,
  }
end

--- Build an item fingerprint from the central chest.
--- @param registry table  must have central_item_adapter, central_item_side, chest_slot_start
--- @param config table     fallback for chest_slot_start
--- @param yield_fn function|nil
--- @return table|nil fp   { slot = count, ... }
--- @return string|nil err
function BufferMonitor.build_fingerprint(registry, config, yield_fn)
  local adapter = registry.central_item_adapter
  if not adapter then return nil, "central item adapter not available" end
  local side = registry.central_item_side
  if type(side) ~= "number" then return nil, "central item side not set" end

  local fp = {}
  local start = registry.chest_slot_start or config.chest_slot_start or 1
  local ok, size = pcall(adapter.getInventorySize, side)
  if not ok or type(size) ~= "number" or size <= 0 then return {} end

  for slot = start, size do
    if slot % 10 == 0 and yield_fn then yield_fn() end
    local ok_st, st = pcall(adapter.getStackInSlot, side, slot)
    if ok_st and type(st) == "table" then
      local count = st.size or 0
      if count > 0 then fp[slot] = count end
    end
  end
  return fp, nil
end

--- Step the buffer monitor state machine.
--- @param self BufferMonitor instance
--- @param now number  current time
--- @param registry table  for fingerprint provider
--- @param config table     for config cascade
--- @param callbacks table  { build_manifest, enqueue_job, check_admission, log }
--- @param pending_jobs table  for batch claim release check
--- @param yield_fn function|nil
--- @param job_stabilize_s number  stabilization timeout
--- @return table  { events = {...} }
function BufferMonitor.step(self, now, registry, config, callbacks, pending_jobs, yield_fn, job_stabilize_s)
  local events = {}
  local log = callbacks.log
  local has_adapter = registry.central_item_adapter ~= nil
    and type(registry.central_item_side) == "number"

  if not has_adapter then
    self._fingerprint = nil
    self._stable_since = 0
    self._batch_claimed = false
    self._batch_job_id = nil
    return { events = events }
  end

  local has_items = false

  if self._state == C.DIS_IDLE then
    local fp, fp_err = BufferMonitor.build_fingerprint(registry, config, yield_fn)
    has_items = fingerprint_nonempty(fp)

    if not has_items then
      self._last_enqueued_fp = nil
      self._batch_claimed = false
      self._batch_job_id = nil
      return { events = events }
    end

    -- Batch claim: if previous batch still active, suppress
    if self._batch_claimed and self._batch_job_id then
      local job_alive = false
      for _, job in ipairs(pending_jobs) do
        if job.id == self._batch_job_id then job_alive = true; break end
      end
      if job_alive then
        if log then log(string.format("[ROB] buf: batch_claimed=true job=%s still pending — suppressing", self._batch_job_id)) end
        return { events = events }
      end
      -- Batch job completed and reaped — release claim
      if log then log(string.format("[ROB] buf: batch_claimed released (job %s reaped)", tostring(self._batch_job_id))) end
      self._batch_claimed = false
      self._batch_job_id = nil
      self._last_enqueued_fp = nil
    end

    -- Same fingerprint suppression
    if fingerprint_equal(fp, self._last_enqueued_fp) then
      return { events = events }
    end

    -- Admission check
    if callbacks.check_admission then
      local ok = callbacks.check_admission()
      if not ok then
        if log then log("[ROB] buf: admission rejected — suppressing job creation") end
        return { events = events }
      end
    end

    -- New items — enter stabilizing
    self._fingerprint = fp
    self._stable_since = now
    self._state = C.DIS_STABILIZING
    if log then log(string.format("[ROB] buf: IDLE -> STABILIZING (fp has %d slots, stabilize_s=%.1f)",
      (function() local n=0; for _ in pairs(fp) do n=n+1 end; return n end)(), job_stabilize_s or 3.0)) end
    events[#events + 1] = { type = "central_buffer_ready", detail = "items in central chest" }

  elseif self._state == C.DIS_STABILIZING then
    local fp, _ = BufferMonitor.build_fingerprint(registry, config, yield_fn)
    has_items = fingerprint_nonempty(fp)

    if not has_items then
      -- Chest emptied during stabilization
      if log then log("[ROB] buf: STABILIZING -> IDLE (chest emptied)") end
      self._state = C.DIS_IDLE
      self._fingerprint = nil
      self._stable_since = 0
      self._batch_claimed = false
      self._batch_job_id = nil
      self._last_enqueued_fp = nil
      return { events = events }
    end

    -- Admission check
    if callbacks.check_admission then
      local ok = callbacks.check_admission()
      if not ok then
        if log then log(string.format("[ROB] buf: admission rejected during STABILIZING (stable for %.1fs)", now - self._stable_since)) end
        return { events = events }
      end
    end

    -- Fingerprint changed — restart timer
    if not fingerprint_equal(fp, self._fingerprint) then
      if log then log(string.format("[ROB] buf: fingerprint changed — reset stabilize timer (was %.1fs)", now - self._stable_since)) end
      self._fingerprint = fp
      self._stable_since = now
      return { events = events }
    end

    -- Not yet stabilized
    local elapsed = now - self._stable_since
    if elapsed < (job_stabilize_s or 3.0) then
      return { events = events }
    end

    -- Stabilized — build manifest and enqueue
    if log then log(string.format("[ROB] buf: stabilized (%.1fs) — building manifest", elapsed)) end
    local manifest = callbacks.build_manifest and callbacks.build_manifest()
    if not manifest or not callbacks.enqueue_job then
      self._state = C.DIS_IDLE
      return { events = events }
    end

    local job, err = callbacks.enqueue_job(manifest)
    self._state = C.DIS_IDLE

    if job then
      self._last_enqueued_fp = fp
      self._batch_claimed = true
      self._batch_job_id = job.id
      if log then log(string.format("[ROB] buf: job %s enqueued, batch_claimed=true", job.id)) end
      events[#events + 1] = { type = "central_job_enqueued", job_id = job.id, detail = "central batch queued" }
    else
      if log then log(string.format("[ROB] buf: enqueue FAILED: %s", tostring(err))) end
      events[#events + 1] = { type = "central_enqueue_failed", detail = err or "unknown" }
    end
  end

  return { events = events }
end

return BufferMonitor
