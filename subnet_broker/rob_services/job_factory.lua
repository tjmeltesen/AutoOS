--[[
  AutoOS — Job Factory
  JIT DB scratchpad allocation + job record creation.
  Contains fluid drop matching (fuzzy_key, match_fluid_drop).
]]
local JobDescriptor = require("rob_core.job_descriptor")

local JobFactory = {}

--- Aggressive fluid name normalization for matching.
local function fuzzy_key(s)
  if type(s) ~= "string" then return nil end
  s = s:lower()
  s = s:gsub("^drop of ", "")
  s = s:gsub("^molten ", "")
  s = s:gsub("^gt%.fluid%.", "")
  s = s:gsub("^[%w]+:[%w]+[%.%-]", "")
  s = s:gsub("^[%w]+:", "")
  s = s:gsub("[^%w]", "")
  return s
end

--- Search AE2 network for a fluid drop matching a fluid step.
local function match_fluid_drop(step, fluid_drops, fluid_network)
  if type(fluid_drops) ~= "table" then return nil end
  local want_raw = (step.fluid_label or step.fluid_registry or ""):lower()
  if want_raw == "" then return nil end
  local want_fuzzy = fuzzy_key(want_raw)

  for _, drop in ipairs(fluid_drops) do
    local dl_raw = (drop.label or ""):lower()
    -- Exact/substring on cleaned originals
    local dl_clean = dl_raw:gsub("^drop of ", ""):gsub("^molten ", "")
    if dl_clean == want_raw
      or dl_clean:find(want_raw, 1, true)
      or want_raw:find(dl_clean, 1, true) then
      return drop
    end
    -- Fuzzy match on stripped forms
    local dl_fuzzy = fuzzy_key(dl_raw)
    if dl_fuzzy and want_fuzzy and dl_fuzzy == want_fuzzy then
      return drop
    end
  end

  -- Cross-reference fluid network names against drop labels
  if type(fluid_network) == "table" and want_fuzzy then
    for _, f in ipairs(fluid_network) do
      local f_name = f.name or f.label or ""
      local f_label = f.label or ""
      if fuzzy_key(f_name) == want_fuzzy or fuzzy_key(f_label) == want_fuzzy then
        for _, drop in ipairs(fluid_drops) do
          if fuzzy_key(drop.label or "") == fuzzy_key(f_label) then
            return drop
          end
        end
      end
    end
  end

  return nil
end

--- JIT scratchpad allocation: clear DB slots 1..N, write each input fresh.
--- Mutates manifest queue entries in-place (db_slot, db_address).
--- @return boolean ok
--- @return string|nil err
function JobFactory.allocate_db_slots(manifest, registry, config, log_fn, yield_fn)
  local db = registry.get_db()
  local iface = registry.get_stock_iface()
  local db_addr = config.database_address
  if not db or not iface then
    return false, "db or iface unavailable"
  end

  local queue = manifest.queue or {}
  local n = #queue
  if n == 0 then return true end

  -- Clear scratchpad range
  for slot = 1, n do pcall(db.clear, slot) end

  -- Pre-fetch fluid drops once
  local fluid_drops = nil
  local fluid_network = nil
  for _, step in ipairs(queue) do
    if step.kind == "fluid" then
      if not fluid_drops and iface.getItemsInNetwork then
        fluid_drops = iface.getItemsInNetwork({ name = "ae2fc:fluid_drop" })
        if type(fluid_drops) ~= "table" or #fluid_drops == 0 then
          fluid_drops = iface.getItemsInNetwork({ name = "ae2fc:fluid_drop1" })
        end
      end
      if not fluid_network and iface.getFluidsInNetwork then
        fluid_network = iface.getFluidsInNetwork()
      end
      break
    end
  end

  local slot = 1
  for _, step in ipairs(queue) do
    if yield_fn then yield_fn() end
    local written = false
    if step.kind == "item" then
      local filter = { name = step.name, damage = step.damage or 0 }
      if step.label then filter.label = step.label end
      if iface.store then
        local ok_store, stored = pcall(iface.store, filter, db_addr, slot, step.count or 1)
        written = ok_store and (stored ~= false)
      end
      if not written then
        local desc = { name = step.name, damage = step.damage or 0, size = step.count or 1 }
        if step.label then desc.label = step.label end
        pcall(db.set, slot, desc)
      end
    elseif step.kind == "fluid" then
      if type(step.fluid_filter) == "table" then
        -- Chest drop: filter already known
        local filter = step.fluid_filter
        if iface.store then
          local ok_store, stored = pcall(iface.store, filter, db_addr, slot, 1)
          written = ok_store and (stored ~= false)
        end
        if not written then
          pcall(db.set, slot, filter)
        end
      else
        -- Central tank fluid: search ME for discretized drop
        local drop = match_fluid_drop(step, fluid_drops, fluid_network)
        if drop then
          local filter = { name = drop.name, damage = drop.damage or 0 }
          if drop.label then filter.label = drop.label end
          if iface.store then
            local ok_store, stored = pcall(iface.store, filter, db_addr, slot, 1)
            written = ok_store and (stored ~= false)
          end
          if not written then
            pcall(db.set, slot, filter)
          end
        else
          -- Registry fallback
          local reg_entry = registry.lookup_fluid_db
            and registry.lookup_fluid_db(step.fluid_label, step.fluid_registry)
          if reg_entry and reg_entry.slot and reg_entry.address then
            local ok_get, desc = pcall(db.get, reg_entry.slot)
            if ok_get and type(desc) == "table" and desc.name then
              if iface.store then
                local ok_store, stored = pcall(iface.store, desc, db_addr, slot, 1)
                written = ok_store and (stored ~= false)
              end
              if not written then
                pcall(db.set, slot, desc)
              end
            end
          end
          if not written then
            local want_raw = tostring(step.fluid_label or step.fluid_registry or "?")
            local want_fuzzy = fuzzy_key(want_raw)
            local ndrops = type(fluid_drops) == "table" and #fluid_drops or 0
            local nfluids = type(fluid_network) == "table" and #fluid_network or 0
            if log_fn then
              log_fn(string.format(
                "[ROBDispatcher] no fluid drop for %q (fuzzy=%q) — %d drops / %d fluids checked",
                want_raw, want_fuzzy or "nil", ndrops, nfluids))
            end
            goto continue_slot
          end
        end
      end
    end
    step.db_slot = slot
    step.db_address = db_addr
    slot = slot + 1
    ::continue_slot::
  end

  -- Validate: every queue step must have a DB pointer
  for _, step in ipairs(queue) do
    if not step.db_slot or not step.db_address then
      return false, string.format("unresolved operand: %s",
        tostring(step.fluid_label or step.name or "?"))
    end
  end
  return true
end

--- Build a job from a manifest and enqueue it.
--- @return table|nil job
--- @return string|nil err
function JobFactory.enqueue(manifest, source, registry, config, log_fn, now_fn, pending_jobs, job_seq, yield_fn)
  local JobManifest = require("rob_core.job_manifest")
  if not JobManifest.has_work(manifest) then
    return nil, "empty manifest"
  end

  local alloc_ok, alloc_err = JobFactory.allocate_db_slots(manifest, registry, config, log_fn, yield_fn)
  if not alloc_ok then
    if log_fn then
      log_fn(string.format("[ROBDispatcher] JIT allocation failed: %s — job NOT enqueued",
        tostring(alloc_err)))
    end
    return nil, alloc_err or "allocation failed"
  end

  if job_seq[1] == 0 then
    if log_fn then
      log_fn("[ROBDispatcher] WARNING fresh _job_seq=0 — dispatcher may have been recreated")
    end
  end
  job_seq[1] = job_seq[1] + 1

  local job_id = string.format("central-%06d", job_seq[1])
  local now = now_fn and now_fn() or 0
  local job = JobDescriptor.create(manifest, source, job_id, now)
  pending_jobs[#pending_jobs + 1] = job

  if log_fn then
    log_fn(string.format("[ROBDispatcher] enqueued job %s  steps=%d  items=%d  fluids=%d",
      job.id,
      #(manifest.queue or {}),
      #(manifest.items or {}),
      #(manifest.fluids or {})))
  end
  return job
end

return JobFactory
