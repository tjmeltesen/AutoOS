--[[
  AutoOS — ROB Dispatcher (Reorder Buffer / Atomic Dispatcher)
  Phase 3: Central buffer monitor + job creation + lane assignment + mutex management.

  Replaces central_dispatch.lua and the dispatch-related parts of array_watch.lua
  (step_scheduler, step_central, step_watchdog, _harvest_finished_jobs).

  Architecture:
    - Single tick() entry point called every scheduler cycle — no yields inside.
    - Registry provides cached hardware proxies (no component.proxy() calls here).
    - Lane workers write completion results to a shared table polled by tick().
    - One central batch = one job = one lane. Never split across lanes.
]]

local FluidTanks = require("fluid_tanks")

local ROBDispatcher = {}
ROBDispatcher.__index = ROBDispatcher

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local FLUID_DROP_ITEM = "ae2fc:fluid_drop"
local DIS_IDLE = "idle"
local DIS_STABILIZING = "stabilizing"
local LANE_IDLE = "IDLE"
local LANE_WORKING = "WORKING"
local LANE_FAULTED = "FAULTED"

---------------------------------------------------------------------------
-- Pure helpers
---------------------------------------------------------------------------

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

local function norm_fluid_label(s)
  if type(s) ~= "string" then return nil end
  s = s:lower()
  s = s:gsub("^drop of ", "")
  s = s:gsub("^molten ", "")
  return s
end

local function fingerprint_nonempty(fp)
  return fp and next(fp) ~= nil
end

---------------------------------------------------------------------------
-- Constructor
---------------------------------------------------------------------------

--- Create a new ROB dispatcher instance.
--- @param registry table  Phase 1 static registry (cached proxies, DB lookups)
---   registry.central_item_adapter   cached adapter proxy for central item chest
---   registry.central_fluid_adapter  cached adapter proxy for central fluid tank
---   registry.central_item_side      adapter side number (integer)
---   registry.central_fluid_side     fluid adapter side number (integer)
---   registry.chest_slot_start       first slot to scan in central chest
---   registry.machines               list of machine config tables
---   registry:lookup_db(name, damage, label) -> { db_slot=, db_address= } or nil
--- @param config  table   Validated Config table (or central subset)
--- @param deps    table   Runtime dependencies
---   deps.now         function() -> seconds   (computer.uptime)
---   deps.log         function(msg)           (print)
---   deps.circuit_manager  table|nil          circuit_manager for admission control
---   deps.max_parallel_lanes  number|nil       concurrency cap (nil = unlimited)
---   deps.max_job_attempts    number           max retries per job (default 2)
---   deps.watchdog_grace_s    number           seconds before watchdog trips (default 10)
--- @return ROBDispatcher
function ROBDispatcher.new(registry, config, deps)
  deps = deps or {}

  local self = setmetatable({}, ROBDispatcher)
  self._registry = registry or error("ROBDispatcher.new: registry required")
  self._config = config or {}
  self._now = deps.now or function() return 0 end
  self._log = deps.log or function() end
  self._circuit_manager = deps.circuit_manager

  self._max_parallel_lanes = deps.max_parallel_lanes
    or (config.scheduler and config.scheduler.max_parallel_lanes)
    or nil
  self._max_job_attempts = deps.max_job_attempts
    or (config.scheduler and config.scheduler.max_job_attempts)
    or 2
  self._watchdog_grace_s = deps.watchdog_grace_s
    or (config.scheduler and config.scheduler.watchdog_grace_s)
    or 10

  -- Buffer monitor state
  self._state = DIS_IDLE
  self._fingerprint = nil          -- fingerprint currently being stabilized
  self._stable_since = 0           -- when the current fingerprint first matched itself
  self._last_enqueued_fp = nil     -- fingerprint that last produced a job
  self._batch_claimed = false      -- suppress re-enqueue until chest contents change

  -- Job queue
  self._pending_jobs = {}          -- FIFO job queue
  self._job_seq = 0                -- monotonic sequence for job IDs

  -- Lane state
  self._lanes = {}                 -- machine_id -> lane state table
  self._locks = {}                 -- global mutex: "interface:uuid" -> owner_machine_id

  -- Completion (Option A: shared table polled by tick)
  self._results = {}               -- machine_id -> { status="done"|"failed", error=... }

  -- Round-robin
  self._rr_index = 1

  return self
end

---------------------------------------------------------------------------
-- Config helpers
---------------------------------------------------------------------------

function ROBDispatcher:_central_cfg()
  return self._config.central or {}
end

function ROBDispatcher:_job_stabilize_s()
  local c = self:_central_cfg()
  return c.job_stabilize_s or c.stabilize_s or 3.0
end

function ROBDispatcher:_max_circuits()
  local c = self:_central_cfg()
  return c.max_circuits_in_buffer or self._config.max_circuits_in_buffer
end

---------------------------------------------------------------------------
-- Lane state management
---------------------------------------------------------------------------

function ROBDispatcher:_lane(machine_id)
  local lane = self._lanes[machine_id]
  if lane then return lane end
  lane = {
    state = LANE_IDLE,
    current_job_id = nil,
    locked_resources = {},
    deadline = 0,           -- watchdog deadline (now + staging_timeout_s)
    state_entered_at = self._now(),
    last_error = nil,
  }
  self._lanes[machine_id] = lane
  return lane
end

function ROBDispatcher:_reset_lane(machine_id, reason)
  local lane = self._lanes[machine_id]
  if lane then
    self:_release_locks(machine_id, lane)
    lane.state = LANE_IDLE
    lane.current_job_id = nil
  end
  self._lanes[machine_id] = {
    state = LANE_IDLE,
    current_job_id = nil,
    locked_resources = {},
    deadline = 0,
    state_entered_at = self._now(),
    last_error = reason,
  }
end

---------------------------------------------------------------------------
-- Buffer monitoring: fingerprint
---------------------------------------------------------------------------

--- Build { slot = size, ... } for non-empty slots in the central chest.
--- Uses cached adapter proxy from registry — no component.proxy() call.
function ROBDispatcher:_item_fingerprint()
  local adapter = self._registry.central_item_adapter
  if not adapter then return nil, "central item adapter not available" end
  local side = self._registry.central_item_side
  if type(side) ~= "number" then return nil, "central item side not set" end

  local fp = {}
  local start = self._registry.chest_slot_start or self._config.chest_slot_start or 1
  -- Determine slot count on adapter
  local ok, size = pcall(adapter.getInventorySize, side)
  if not ok or type(size) ~= "number" or size <= 0 then return {} end

  for slot = start, size do
    local ok_st, st = pcall(adapter.getStackInSlot, side, slot)
    if ok_st and type(st) == "table" then
      local count = st.size or 0
      if count > 0 then fp[slot] = count end
    end
  end
  return fp, nil
end

---------------------------------------------------------------------------
-- Fluid tank reading
---------------------------------------------------------------------------

--- Read non-empty tanks from central fluid adapter (cached proxy from registry).
--- Returns a list of { fluid_label, fluid_registry, fluid_amount_mb, fluid_tank_index }.
function ROBDispatcher:_fluids_from_central_tank()
  local adapter = self._registry.central_fluid_adapter
  if not adapter then return {} end
  local side = self._registry.central_fluid_side
  if type(side) ~= "number" then return {} end

  local c = self:_central_cfg()
  local label_map = type(c.fluid_label_map) == "table" and c.fluid_label_map or {}
  local out = {}

  for _, row in ipairs(FluidTanks.non_empty_tanks(adapter, side)) do
    local raw = tostring(row.name or "")
    local mapped = label_map[raw] or label_map[norm_fluid_label(raw)] or raw
    out[#out + 1] = {
      fluid_label = mapped,
      fluid_registry = norm_fluid_label(raw) or raw,
      fluid_amount_mb = row.amount,
      fluid_source = "central_tank",
      fluid_tank_index = row.idx,
    }
  end
  return out
end

---------------------------------------------------------------------------
-- Manifest building
---------------------------------------------------------------------------

--- Read a stack from the cached adapter proxy (pcall-safe).
--- @return table|nil  stack table or nil if empty/invalid
local function _stack_on_adapter(adapter, side, slot)
  if not adapter then return nil end
  local ok, st = pcall(adapter.getStackInSlot, side, slot)
  if not ok or type(st) ~= "table" then return nil end
  if (st.size or 0) < 1 then return nil end
  return st
end

--- Build the full batch manifest from central chest + central tank.
--- @return table { items={...}, fluids={...}, queue={...} }
function ROBDispatcher:_build_manifest()
  local adapter = self._registry.central_item_adapter
  if not adapter then return { items = {}, fluids = {}, queue = {} } end
  local side = self._registry.central_item_side
  if type(side) ~= "number" then return { items = {}, fluids = {}, queue = {} } end

  local out = { items = {}, fluids = {}, queue = {} }
  local seen_fluids = {}
  local start = self._registry.chest_slot_start or self._config.chest_slot_start or 1

  local ok_size, size = pcall(adapter.getInventorySize, side)
  if not ok_size or type(size) ~= "number" then
    -- inventory_controller may lie about size; scan a generous range
    size = start + 53
  end

  for slot = start, size do
    local st = _stack_on_adapter(adapter, side, slot)
    if st then
      if st.name == FLUID_DROP_ITEM then
        -- AE2 fluid drop item in chest
        local fluid_label = st.label and st.label:gsub("^drop of ", "") or nil
        local fluid_spec = {
          fluid_label = fluid_label,
          fluid_filter = { name = st.name, damage = st.damage or 0, label = st.label },
        }
        out.fluids[#out.fluids + 1] = fluid_spec
        out.queue[#out.queue + 1] = {
          kind = "fluid",
          fluid_label = fluid_label,
          fluid_filter = fluid_spec.fluid_filter,
          fluid_source = "chest_drop",
          slot = slot,
        }
        local key = norm_fluid_label(fluid_label)
        if key then seen_fluids[key] = true end
      else
        -- Regular item
        local item_spec = {
          slot = slot,
          name = st.name,
          damage = st.damage or 0,
          label = st.label,
          count = st.size or 1,
        }
        out.items[#out.items + 1] = item_spec
        out.queue[#out.queue + 1] = {
          kind = "item",
          slot = slot,
          name = item_spec.name,
          damage = item_spec.damage,
          label = item_spec.label,
          count = item_spec.count,
        }
      end
    end
  end

  -- Append fluids from central tank that aren't already present as chest drops
  for _, fluid in ipairs(self:_fluids_from_central_tank()) do
    local key = norm_fluid_label(fluid.fluid_label)
    if not key or not seen_fluids[key] then
      out.fluids[#out.fluids + 1] = fluid
      out.queue[#out.queue + 1] = {
        kind = "fluid",
        fluid_label = fluid.fluid_label,
        fluid_registry = fluid.fluid_registry,
        fluid_amount_mb = fluid.fluid_amount_mb,
        fluid_source = fluid.fluid_source,
        fluid_tank_index = fluid.fluid_tank_index,
      }
      if key then seen_fluids[key] = true end
    end
  end

  return out
end

--- True if the manifest has any work to do.
function ROBDispatcher:_manifest_has_work(manifest)
  return manifest
    and ((type(manifest.items) == "table" and #manifest.items > 0)
      or (type(manifest.fluids) == "table" and #manifest.fluids > 0)
      or (type(manifest.queue) == "table" and #manifest.queue > 0))
end

---------------------------------------------------------------------------
-- Circuit admission control
---------------------------------------------------------------------------

function ROBDispatcher:_count_circuits()
  local adapter = self._registry.central_item_adapter
  if not adapter or not self._circuit_manager then return 0 end
  local side = self._registry.central_item_side
  if type(side) ~= "number" then return 0 end

  local n = 0
  local start = self._registry.chest_slot_start or self._config.chest_slot_start or 1
  local ok_size, size = pcall(adapter.getInventorySize, side)
  if not ok_size or type(size) ~= "number" then return 0 end

  for slot = start, size do
    local ok_st, st = pcall(adapter.getStackInSlot, side, slot)
    if ok_st and self._circuit_manager.stack_is_circuit
      and self._circuit_manager:stack_is_circuit(st) then
      n = n + 1
    end
  end
  return n
end

function ROBDispatcher:_admission_ok()
  local max_circ = self:_max_circuits()
  if not max_circ or max_circ < 1 then return true end
  local n = self:_count_circuits()
  if n > max_circ then
    self._log(string.format("[ROBDispatcher] buffer has %d circuits (max %d) — suppressing dispatch", n, max_circ))
    return false
  end
  return true
end

---------------------------------------------------------------------------
-- Job creation
---------------------------------------------------------------------------

--- JIT scratchpad allocation: clear DB slots 1..N, write each input fresh.
--- Mutates manifest entries in-place, filling in db_slot and db_address.
--- One recipe at a time = no caching needed; slots are working memory only.
function ROBDispatcher:_allocate_db_slots(manifest)
  local db = self._registry.get_db()
  local iface = self._registry.get_stock_iface()
  local db_addr = self._config.database_address
  if not db or not iface then
    self._log("[ROBDispatcher] _allocate_db_slots: db or iface unavailable")
    return false, "db or iface unavailable"
  end

  local queue = manifest.queue or {}
  local n = #queue
  if n == 0 then return true end  -- nothing to allocate, not an error

  -- Clear scratchpad range
  for slot = 1, n do pcall(db.clear, slot) end

  -- Pre-fetch fluid drops once for all fluid steps.
  -- Also snapshot getFluidsInNetwork() so we can cross-reference fluid names
  -- against drop labels — GTNH internal names (carbonmonoxide) may differ
  -- from display labels (Carbon Monoxide).
  local fluid_drops = nil
  local fluid_network = nil  -- raw getFluidsInNetwork() result
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

  -- Fuzzy-normalize a fluid name for comparison: lowercase, strip
  -- "drop of "/"molten " prefixes, GTNH/Forge namespace prefixes,
  -- and all non-alphanumeric characters so that "Carbon Monoxide",
  -- "carbon_monoxide", and "gt.fluid.carbonmonoxide" all collide.
  local function fuzzy_key(s)
    if type(s) ~= "string" then return nil end
    s = s:lower()
    s = s:gsub("^drop of ", "")
    s = s:gsub("^molten ", "")
    s = s:gsub("^gt%.fluid%.", "")
    s = s:gsub("^[%w]+:[%w]+[%.%-]", "")  -- modid:prefix. or modid:prefix-
    s = s:gsub("^[%w]+:", "")              -- bare modid: (ic2:, gregtech:, etc.)
    s = s:gsub("[^%w]", "")  -- strip spaces, underscores, dots, hyphens
    return s
  end

  local function match_fluid_drop(step)
    if type(fluid_drops) ~= "table" then return nil end
    local want_raw = (step.fluid_label or step.fluid_registry or ""):lower()
    if want_raw == "" then return nil end
    local want_fuzzy = fuzzy_key(want_raw)

    for _, drop in ipairs(fluid_drops) do
      local dl_raw = (drop.label or ""):lower()
      -- Exact/substring on cleaned originals (existing behavior)
      local dl_clean = dl_raw:gsub("^drop of ", ""):gsub("^molten ", "")
      if dl_clean == want_raw
        or dl_clean:find(want_raw, 1, true)
        or want_raw:find(dl_clean, 1, true) then
        return drop
      end
      -- Fuzzy match on stripped forms (handles space/underscore/dot mismatches)
      local dl_fuzzy = fuzzy_key(dl_raw)
      if dl_fuzzy and want_fuzzy and dl_fuzzy == want_fuzzy then
        return drop
      end
    end

    -- Cross-reference getFluidsInNetwork names against drop labels.
    -- If a raw fluid name fuzzy-matches our target, we can try to find
    -- the corresponding drop by cross-referencing the fluid's label.
    if type(fluid_network) == "table" and want_fuzzy then
      for _, f in ipairs(fluid_network) do
        local f_name = f.name or f.label or ""
        local f_label = f.label or ""
        if fuzzy_key(f_name) == want_fuzzy or fuzzy_key(f_label) == want_fuzzy then
          -- Fluid exists in network — try matching its label against drops
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

  local slot = 1
  for _, step in ipairs(queue) do
    local written = false
    if step.kind == "item" then
      local filter = { name = step.name, damage = step.damage or 0 }
      if step.label then filter.label = step.label end
      if iface.store then
        local ok_s = pcall(iface.store, filter, db_addr, slot, step.count or 1)
        written = ok_s
      end
      if not written then
        local desc = { name = step.name, damage = step.damage or 0, size = step.count or 1 }
        if step.label then desc.label = step.label end
        pcall(db.set, slot, desc)
      end
    elseif step.kind == "fluid" then
      if type(step.fluid_filter) == "table" then
        -- Chest drop: filter already known, no ME search needed.
        local filter = step.fluid_filter
        if iface.store then
          local ok_s = pcall(iface.store, filter, db_addr, slot, 1)
          written = ok_s
        end
        if not written then
          pcall(db.set, slot, filter)
        end
      else
        -- Central tank fluid: must search ME for a discretized drop.
        local drop = match_fluid_drop(step)
        if drop then
          local filter = { name = drop.name, damage = drop.damage or 0 }
          if drop.label then filter.label = drop.label end
          if iface.store then
            local ok_s = pcall(iface.store, filter, db_addr, slot, 1)
            written = ok_s
          end
          if not written then
            pcall(db.set, slot, filter)
          end
        else
          -- Try registry fallback before giving up.
          -- If the DB persisted descriptors from a previous session, the
          -- boot-time scan may have cached them even when the ME network
          -- search finds nothing.
          local reg_entry = self._registry.lookup_fluid_db
            and self._registry.lookup_fluid_db(step.fluid_label, step.fluid_registry)
          if reg_entry and reg_entry.slot and reg_entry.address then
            local ok_get, desc = pcall(db.get, reg_entry.slot)
            if ok_get and type(desc) == "table" and desc.name then
              if iface.store then
                local ok_s = pcall(iface.store, desc, db_addr, slot, 1)
                written = ok_s
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
            self._log(string.format(
              "[ROBDispatcher] no fluid drop for %q (fuzzy=%q) — %d drops / %d fluids checked",
              want_raw, want_fuzzy or "nil", ndrops, nfluids))
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

  -- Validate: every queue step must have a stable DB pointer.
  -- Reject the job if any operand failed to resolve — a partial
  -- delivery would corrupt the recipe.
  for _, step in ipairs(queue) do
    if not step.db_slot or not step.db_address then
      return false, string.format("unresolved operand: %s",
        tostring(step.fluid_label or step.name or "?"))
    end
  end
  return true
end

--- Build a job object from a manifest and enqueue it.
--- @return table|nil job
--- @return string|nil err
function ROBDispatcher:_enqueue_job(manifest, source)
  if not self:_manifest_has_work(manifest) then
    return nil, "empty manifest"
  end

  local alloc_ok, alloc_err = self:_allocate_db_slots(manifest)
  if not alloc_ok then
    self._log(string.format("[ROBDispatcher] JIT allocation failed: %s — job NOT enqueued",
      tostring(alloc_err)))
    return nil, alloc_err or "allocation failed"
  end

  self._job_seq = self._job_seq + 1
  local job = {
    id = string.format("central-%06d", self._job_seq),
    source = source or "central",
    status = "pending",
    manifest = manifest,
    attempt = 1,
    created_at = self._now(),
    machine_id = nil,
  }
  self._pending_jobs[#self._pending_jobs + 1] = job

  self._log(string.format("[ROBDispatcher] enqueued job %s  steps=%d  items=%d  fluids=%d",
    job.id,
    #(manifest.queue or {}),
    #(manifest.items or {}),
    #(manifest.fluids or {})))
  return job
end

---------------------------------------------------------------------------
-- Resource / mutex locking
---------------------------------------------------------------------------

--- Build the list of resource keys a machine's job needs to lock.
function ROBDispatcher:_job_resources(machine)
  local resources = {}

  -- Interface address lock (shared interface or per-machine)
  local iface = machine.interface_address
    or self._config.shared_interface_address
  if iface and iface ~= "" then
    resources[#resources + 1] = "interface:" .. tostring(iface)
  end

  -- Transposer locks
  if machine.item_transposer_address then
    resources[#resources + 1] = "tp:" .. tostring(machine.item_transposer_address)
  end
  if machine.fluid_transposer_address then
    resources[#resources + 1] = "tp:" .. tostring(machine.fluid_transposer_address)
  end

  return resources
end

--- Acquire global mutex locks for a set of resources.
--- Fails if any resource is already locked by a different machine.
--- @return boolean ok
--- @return string|nil err
function ROBDispatcher:_acquire_locks(machine_id, resources)
  -- Check first (two-phase to avoid partial acquisition)
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

--- Release all mutex locks held by a machine.
function ROBDispatcher:_release_locks(machine_id, lane)
  local resources = lane and lane.locked_resources
  if resources then
    for _, res in ipairs(resources) do
      if self._locks[res] == machine_id then
        self._locks[res] = nil
      end
    end
  end
  -- Also scan the lock table to clean up any stale entries for this machine
  for res, owner in pairs(self._locks) do
    if owner == machine_id then self._locks[res] = nil end
  end
  if lane then
    lane.locked_resources = {}
  end
end

---------------------------------------------------------------------------
-- Machine availability checks
---------------------------------------------------------------------------

--- Determine if a machine is available for dispatch.
--- @param machine table  machine config
--- @param poll_status table  poll result for this machine
--- @return boolean
function ROBDispatcher:_machine_available(machine, poll_status)
  if not machine or not machine.id then return false end

  -- Must have a poll result
  if not poll_status then return false end
  if not poll_status.available then return false end
  if not poll_status.healthy then return false end

  -- Machine must be idle (not actively crafting)
  if poll_status.active or poll_status.has_work then return false end

  -- Lane must be IDLE — auto-recover if machine is healthy but lane is faulted.
  -- FAULTED lanes are never manually recovered (recover_lane has zero callers),
  -- so we recover here when the poll confirms the machine is ready for work.
  local lane = self._lanes[machine.id]
  if lane then
    if lane.state == LANE_FAULTED
      and poll_status.available
      and poll_status.healthy
      and not poll_status.active
      and not poll_status.has_work then
      self:recover_lane(machine.id)
    end
    if lane.state ~= LANE_IDLE then return false end
  end

  return true
end

--- Round-robin through machines to find one that is available.
--- @param poll_results table  machine_id -> poll status
--- @return table|nil machine
--- @return number|nil index (1-based in machines list)
function ROBDispatcher:_find_available_machine_rr(poll_results)
  local machines = self._registry.machines or self._config.machines or {}
  local n = #machines
  if n == 0 then return nil, nil end

  local start = self._config.do_round_robin ~= false and self._rr_index or 1

  for i = 0, n - 1 do
    local idx = ((start - 1 + i) % n) + 1
    local m = machines[idx]
    local st = poll_results and poll_results[m.id]
    if self:_machine_available(m, st) then
      return m, idx
    end
  end

  return nil, nil
end

--- Advance the round-robin cursor after a successful assignment.
function ROBDispatcher:_advance_rr(idx)
  local machines = self._registry.machines or self._config.machines or {}
  local n = #machines
  if self._config.do_round_robin ~= false and n > 0 then
    self._rr_index = (idx % n) + 1
  end
end

---------------------------------------------------------------------------
-- Completion polling (Option A: shared result table)
---------------------------------------------------------------------------

--- Poll self._results for completed jobs.
--- Releases locks, transitions lane state, and removes consumed results.
function ROBDispatcher:_poll_completions()
  for machine_id, result in pairs(self._results) do
    local lane = self._lanes[machine_id]
    if lane and lane.state == LANE_WORKING then
      if result.status == "done" then
        self._log(string.format("[ROBDispatcher] %s job complete: %s", machine_id, tostring(lane.current_job_id)))
        lane.last_error = nil
        self:_release_locks(machine_id, lane)
        lane.state = LANE_IDLE
        lane.current_job_id = nil
        lane.state_entered_at = self._now()
      elseif result.status == "failed" then
        local err = result.error or "unknown error"
        self._log(string.format("[ROBDispatcher] %s job failed: %s — %s", machine_id, tostring(lane.current_job_id), err))
        lane.last_error = err
        self:_release_locks(machine_id, lane)
        lane.state = LANE_FAULTED
        lane.current_job_id = nil
        lane.state_entered_at = self._now()
      end
    end
    self._results[machine_id] = nil
  end
end

---------------------------------------------------------------------------
-- Watchdog
---------------------------------------------------------------------------

--- Check for watchdog timeouts on WORKING lanes.
--- Transitions timed-out lanes to FAULTED and releases locks.
function ROBDispatcher:_check_watchdogs(now)
  local staging_timeout = self._config.staging_timeout_s or 60
  local grace = self._watchdog_grace_s

  for machine_id, lane in pairs(self._lanes) do
    if lane.state == LANE_WORKING and lane.deadline > 0 then
      if now > lane.deadline + grace then
        local detail = string.format("watchdog timeout in WORKING (deadline=%.0f grace=%d)", lane.deadline, grace)
        self._log(string.format("[ROBDispatcher] %s %s", machine_id, detail))
        lane.last_error = detail
        self:_release_locks(machine_id, lane)
        lane.state = LANE_FAULTED
        lane.current_job_id = nil
        lane.state_entered_at = now
      end
    end
  end
end

---------------------------------------------------------------------------
-- Job reaping: update job status based on lane results
---------------------------------------------------------------------------

--- Walk the job queue and update status for jobs whose lane has finished.
--- Jobs completed (done) are removed. Jobs failed are requeued or marked dead.
function ROBDispatcher:_reap_jobs()
  -- Check each lane for a just-completed job
  -- (This is handled by _poll_completions above; here we clean the job queue)
  local i = #self._pending_jobs
  while i >= 1 do
    local job = self._pending_jobs[i]
    if job.status == "done" then
      -- Remove completed jobs
      table.remove(self._pending_jobs, i)
    elseif job.status == "failed" then
      if (job.attempt or 1) < self._max_job_attempts then
        job.attempt = (job.attempt or 1) + 1
        job.status = "pending"
        job.machine_id = nil
        self._log(string.format("[ROBDispatcher] job %s requeued (attempt %d/%d)",
          job.id, job.attempt, self._max_job_attempts))
      else
        job.status = "dead"
        self._log(string.format("[ROBDispatcher] job %s dead after %d attempts: %s",
          job.id, job.attempt or 1, tostring(job.last_error)))
        table.remove(self._pending_jobs, i)
      end
    elseif job.status == "dead" then
      table.remove(self._pending_jobs, i)
    end
    i = i - 1
  end
end

---------------------------------------------------------------------------
-- Job assignment
---------------------------------------------------------------------------

--- Compute how many more lanes can be assigned right now.
function ROBDispatcher:_available_lane_budget()
  local max = self._max_parallel_lanes
  if not max or max < 1 then
    max = #(self._registry.machines or self._config.machines or {})
  end
  local active = 0
  for _, lane in pairs(self._lanes) do
    if lane.state == LANE_WORKING then active = active + 1 end
  end
  return math.max(0, max - active)
end

--- Try to assign pending jobs to IDLE lanes.
--- @param poll_results table  machine_id -> poll status
--- @return table  list of machine IDs assigned this tick
function ROBDispatcher:_assign_jobs(poll_results)
  local assigned = {}
  local budget = self:_available_lane_budget()
  if budget <= 0 then return assigned end

  -- Scan each pending job, try to match with an available machine
  for _, job in ipairs(self._pending_jobs) do
    if budget <= 0 then break end
    if job.status == "pending" then
      local machine, idx = self:_find_available_machine_rr(poll_results)
      if machine then
        -- Acquire resource locks
        local resources = self:_job_resources(machine)
        local ok_lock, lock_err = self:_acquire_locks(machine.id, resources)
        if not ok_lock then
          job.last_blocked_reason = lock_err
          -- Rotate RR past this machine so others get a chance
          self:_advance_rr(idx)
        else
          -- Assign job to lane
          local lane = self:_lane(machine.id)
          lane.state = LANE_WORKING
          lane.current_job_id = job.id
          lane.locked_resources = resources
          lane.deadline = self._now() + (self._config.completion_timeout_s
            or self._config.staging_timeout_s or 60)
          lane.state_entered_at = self._now()
          lane.last_error = nil

          job.status = "running"
          job.machine_id = machine.id
          job.started_at = self._now()

          self:_advance_rr(idx)
          assigned[#assigned + 1] = machine.id
          budget = budget - 1

          self._log(string.format("[ROBDispatcher] dispatched job %s -> %s (attempt %d)",
            job.id, machine.id, job.attempt or 1))
        end
      else
        -- No machine available for this job; try next job
        -- (different jobs might be assignable to different machines)
      end
    end
  end

  return assigned
end

---------------------------------------------------------------------------
-- Buffer monitor state machine (fingerprint → stabilize → enqueue)
---------------------------------------------------------------------------

--- Core central buffer monitoring in a single synchronous step.
--- @return table  events emitted this tick
function ROBDispatcher:_step_buffer_monitor()
  local events = {}
  local now = self._now()

  -- Read cached adapter proxy for fingerprinting
  local adapter = self._registry.central_item_adapter
  local side = self._registry.central_item_side

  if not adapter or type(side) ~= "number" then
    -- No adapter configured or available — remain idle
    if self._state ~= DIS_IDLE then
      self._state = DIS_IDLE
      self._fingerprint = nil
      self._stable_since = 0
    end
    return events
  end

  local fp, fp_err = self:_item_fingerprint()
  if fp_err then
    -- Adapter error — treat as empty
    fp = {}
  end
  local has_items = fingerprint_nonempty(fp)

  -- ── DIS_IDLE ──────────────────────────────────────────────────────
  if self._state == DIS_IDLE then
    if not has_items then
      -- Chest is empty — reset all suppression state
      self._last_enqueued_fp = nil
      self._batch_claimed = false
      return events
    end

    -- Suppress: a batch was already claimed.  If the fingerprint differs
    -- from what we last enqueued, AE2 has already started pulling items —
    -- release the claim so we can enqueue the next batch.
    if self._batch_claimed then
      if not fingerprint_equal(fp, self._last_enqueued_fp) then
        self._batch_claimed = false
      else
        return events
      end
    end

    -- Suppress: the fingerprint matches what we last enqueued
    if fingerprint_equal(fp, self._last_enqueued_fp) then return events end

    -- Admission control: don't start if there are too many circuits
    if not self:_admission_ok() then return events end

    -- New items detected → start stabilizing
    self._fingerprint = fp
    self._stable_since = now
    self._state = DIS_STABILIZING
    self._log("[ROBDispatcher] items in central chest → stabilizing")
    events[#events + 1] = { type = "central_buffer_ready", detail = "items in central chest" }
    return events
  end

  -- ── DIS_STABILIZING ───────────────────────────────────────────────
  if self._state == DIS_STABILIZING then
    if not has_items then
      -- Chest emptied during stabilization — abort
      self._state = DIS_IDLE
      self._batch_claimed = false
      self._last_enqueued_fp = nil
      self._fingerprint = nil
      self._stable_since = 0
      return events
    end

    -- Admission check
    if not self:_admission_ok() then return events end

    -- Fingerprint changed — restart the stabilization timer
    if not fingerprint_equal(fp, self._fingerprint) then
      self._fingerprint = fp
      self._stable_since = now
      return events
    end

    -- Check if stable long enough
    local stable_for = now - self._stable_since
    local required = self:_job_stabilize_s()
    if stable_for < required then
      -- Still stabilizing — no-op
      return events
    end

    -- Stabilized — build manifest and enqueue
    local manifest = self:_build_manifest()
    if not self:_manifest_has_work(manifest) then
      self._state = DIS_IDLE
      self._fingerprint = nil
      self._stable_since = 0
      events[#events + 1] = { type = "central_wait_output", detail = "central chest empty after stabilize" }
      return events
    end

    local job, enqueue_err = self:_enqueue_job(manifest, "live")
    self._last_enqueued_fp = fp
    self._batch_claimed = true
    self._state = DIS_IDLE
    self._fingerprint = nil
    self._stable_since = 0

    if not job then
      events[#events + 1] = { type = "central_enqueue_failed", detail = tostring(enqueue_err) }
      return events
    end

    self._log(string.format("[ROBDispatcher] stable %.1fs → job %s enqueued", stable_for, job.id))
    events[#events + 1] = { type = "central_job_enqueued", job_id = job.id, detail = "central batch queued" }
    return events
  end

  return events
end

---------------------------------------------------------------------------
-- Main entry point: tick()
---------------------------------------------------------------------------

--- Called every scheduler cycle. Does all work synchronously (no yields).
---
--- 1. Poll completion results from lane workers
--- 2. Reap finished/failed jobs from the queue
--- 3. Check watchdog timeouts
--- 4. Monitor central buffer (fingerprint → stabilize → manifest → enqueue)
--- 5. Assign pending jobs to IDLE lanes
---
--- @param poll_results table  machine_id -> { available, healthy, active, has_work, ... }
--- @return table { events = {...}, jobs_assigned = {...} }
function ROBDispatcher:tick(poll_results)
  poll_results = poll_results or {}
  local now = self._now()

  -- Phase 1: Completion detection
  self:_poll_completions()

  -- Phase 2: Job reaping (mark done/failed/dead in queue)
  self:_reap_jobs()

  -- Phase 3: Watchdog
  self:_check_watchdogs(now)

  -- Phase 4: Central buffer monitor
  local events = self:_step_buffer_monitor()

  -- Phase 5: Job assignment
  local jobs_assigned = self:_assign_jobs(poll_results)

  -- Emit event for each assignment (so array_watch layer can update health)
  for _, machine_id in ipairs(jobs_assigned) do
    events[#events + 1] = {
      type = "central_staged",
      machine_id = machine_id,
      detail = "dispatched -> " .. machine_id,
    }
  end

  return { events = events, jobs_assigned = jobs_assigned }
end

---------------------------------------------------------------------------
-- Result reporting (for lane workers to write completion)
---------------------------------------------------------------------------

--- Get the shared results table that lane workers write completion to.
--- The lane worker should set: self._results[machine_id] = { status="done"|"failed", error=... }
--- @return table
function ROBDispatcher:get_results_table()
  return self._results
end

--- Mark a lane as faulted externally (e.g., from array_watch layer on maintenance fault).
--- @param machine_id string
--- @param reason string
function ROBDispatcher:fault_lane(machine_id, reason)
  local lane = self:_lane(machine_id)
  lane.state = LANE_FAULTED
  lane.current_job_id = nil
  lane.last_error = reason
  lane.state_entered_at = self._now()
  self:_release_locks(machine_id, lane)
  self._log(string.format("[ROBDispatcher] %s FAULTED: %s", machine_id, reason))
end

--- Mark a faulted lane as recovered and ready for new work.
--- @param machine_id string
function ROBDispatcher:recover_lane(machine_id)
  local lane = self._lanes[machine_id]
  if lane and lane.state == LANE_FAULTED then
    lane.state = LANE_IDLE
    lane.current_job_id = nil
    lane.last_error = nil
    lane.locked_resources = {}
    lane.state_entered_at = self._now()
    self:_release_locks(machine_id, lane)
    self._log(string.format("[ROBDispatcher] %s RECOVERED", machine_id))
  end
end

---------------------------------------------------------------------------
-- Debug / introspection
---------------------------------------------------------------------------

function ROBDispatcher:get_debug()
  local lanes = {}
  for mid, lane in pairs(self._lanes) do
    lanes[mid] = {
      state = lane.state,
      current_job_id = lane.current_job_id,
      deadline = lane.deadline,
      last_error = lane.last_error,
    }
  end
  return {
    buffer_state = self._state,
    pending_jobs = #self._pending_jobs,
    rr_index = self._rr_index,
    stable_for = self._fingerprint and (self._now() - self._stable_since) or 0,
    batch_claimed = self._batch_claimed,
    lanes = lanes,
    active_locks = #(next(self._locks) and self._locks or {}),
  }
end

function ROBDispatcher:any_fast_tick()
  if self._state ~= DIS_IDLE then return true end
  for _, lane in pairs(self._lanes) do
    if lane.state == LANE_WORKING then return true end
  end
  return false
end

function ROBDispatcher:pending_count()
  return #self._pending_jobs
end

function ROBDispatcher:pending_queue()
  return self._pending_jobs
end

--- Get the job currently assigned to a lane (if any).
--- Lane workers call this to pull their work after being woken.
--- @param machine_id string
--- @return table|nil job
function ROBDispatcher:get_assigned_job(machine_id)
  local lane = self._lanes[machine_id]
  if not lane or lane.state ~= LANE_WORKING or not lane.current_job_id then
    return nil
  end
  for _, job in ipairs(self._pending_jobs) do
    if job.id == lane.current_job_id then return job end
  end
  return nil
end

--- Check if a specific lane is busy (WORKING or FAULTED).
--- @param machine_id string
--- @return boolean
function ROBDispatcher:is_lane_busy(machine_id)
  local lane = self._lanes[machine_id]
  return lane and lane.state ~= LANE_IDLE
end

--- Check if a specific lane is faulted.
--- @param machine_id string
--- @return boolean
function ROBDispatcher:is_lane_faulted(machine_id)
  local lane = self._lanes[machine_id]
  return lane and lane.state == LANE_FAULTED
end

--- Release all locks unconditionally (used on hard reset).
function ROBDispatcher:release_all_locks()
  for machine_id, lane in pairs(self._lanes) do
    self:_release_locks(machine_id, lane)
  end
  self._locks = {}
end

return ROBDispatcher
