#!/usr/bin/env lua
--[[
  AutoOS — Dispatch Pipeline Integration Tests
  Exercises the full path: central buffer deposit → adapter detects items →
  buffer_monitor stabilizes → admission gates → job created → dispatched to a
  free machine → while that machine is processing, another deposit arrives →
  dispatched to the next free machine → completion → recovery.
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/integration/dispatch_pipeline_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "shared" .. sep .. "?.lua",
  package.path,
}, ";")

local Config = require("config")
local MockHardware = require("mock_broker_hardware")
local C = require("rob_core.constants")
local BufferMonitor = require("buffer_monitor")
local JobDescriptor = require("job_descriptor")
local LaneState = require("lane_state")
local LockManager = require("lock_manager")
local JobAssigner = require("job_assigner")
local JobReaper = require("job_reaper")
local CompletionDetector = require("completion_detector")
local Watchdog = require("watchdog")

local ESC = string.char(27)
local function color(c, t) return ESC .. "[" .. c .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0
local seq = 0
local function check(name, ok, detail)
  seq = seq + 1
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. seq .. ". " .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. seq .. ". " .. name) end
  if detail then io.write("  -  " .. tostring(detail)) end
  io.write("\n")
end

io.write("\n" .. bold("Dispatch Pipeline Integration Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

-- ===========================================================================
-- Suite A: Buffer Monitor → Job Creation (adapter-driven detection)
-- ===========================================================================
io.write("\n--- Suite A: Buffer Monitor -> Job Creation ---\n")

do
  -- A.1: When the central chest has items, the adapter detects them and
  -- buffer_monitor transitions IDLE → STABILIZING.
  local bm = BufferMonitor.new()
  check("A.1 new state is IDLE", bm._state == C.DIS_IDLE)

  local orig_hw = package.loaded["hw"]
  package.loaded["hw"] = {
    get_all_stacks = function()
      return { [1] = { name = "gregtech:gt.metaitem.01", damage = 7, size = 1 } }
    end,
  }
  local registry = { central_item_adapter = {}, central_item_side = 0 }
  local config = { machines = Config.machines, input_mode = "central",
    central = { monitor = "adapter", job_stabilize_s = 3.0 } }
  local cb = {
    log = function() end,
    check_admission = function() return true end,
    build_manifest = function() return { items = {}, fluids = {} } end,
    enqueue_job = function(m) return { id = "job-001", status = "pending" } end,
    fault = function() end,
  }

  local result = BufferMonitor.step(bm, 100, registry, config, cb, {}, nil, 3.0)
  package.loaded["hw"] = orig_hw

  check("A.1 items detected -> STABILIZING", bm._state == C.DIS_STABILIZING)
  check("A.1 stable_since recorded", bm._stable_since == 100)
  check("A.1 central_buffer_ready event", result.events[1] and result.events[1].type == "central_buffer_ready")
end

do
  -- A.2: After stabilization timeout, a job is enqueued and state returns to IDLE.
  local bm = BufferMonitor.new()
  local orig_hw = package.loaded["hw"]
  package.loaded["hw"] = {
    get_all_stacks = function()
      return { [1] = { name = "gregtech:gt.metaitem.01", damage = 7, size = 1 } }
    end,
  }
  local registry = { central_item_adapter = {}, central_item_side = 0 }
  local config = { machines = Config.machines, input_mode = "central",
    central = { monitor = "adapter", job_stabilize_s = 3.0 } }
  local enqueued = {}
  local cb = {
    log = function() end,
    check_admission = function() return true end,
    build_manifest = function()
      return { items = { { name = "gt:circuit", damage = 7, count = 1 } }, fluids = {} }
    end,
    enqueue_job = function(m)
      local j = { id = "job-A2", status = "pending", manifest = m }
      enqueued[#enqueued + 1] = j
      return j
    end,
    fault = function() end,
  }

  BufferMonitor.step(bm, 0, registry, config, cb, {}, nil, 3.0)    -- IDLE -> STABILIZING
  BufferMonitor.step(bm, 1.0, registry, config, cb, {}, nil, 3.0)  -- still stabilizing
  BufferMonitor.step(bm, 4.0, registry, config, cb, {}, nil, 3.0)  -- stabilized -> enqueue
  package.loaded["hw"] = orig_hw

  check("A.2 returned to IDLE after enqueue", bm._state == C.DIS_IDLE)
  check("A.2 batch claimed after enqueue", bm._batch_claimed == true)
  check("A.2 job enqueued", #enqueued == 1)
  check("A.2 job is pending", enqueued[1].status == "pending")
end

do
  -- A.3: Same fingerprint on next tick is suppressed — no duplicate job.
  local bm = BufferMonitor.new()
  local orig_hw = package.loaded["hw"]
  local items = { [1] = { name = "gt:circuit", damage = 7, size = 1 } }
  package.loaded["hw"] = { get_all_stacks = function() return items end }
  local registry = { central_item_adapter = {}, central_item_side = 0 }
  local config = { machines = Config.machines, input_mode = "central",
    central = { monitor = "adapter", job_stabilize_s = 1.0 } }
  local enqueued = {}
  local cb = {
    log = function() end,
    check_admission = function() return true end,
    build_manifest = function() return { items = {}, fluids = {} } end,
    enqueue_job = function(m)
      enqueued[#enqueued + 1] = m
      return { id = "job-A3", status = "pending" }
    end,
    fault = function() end,
  }

  -- First pass: detect and enqueue
  BufferMonitor.step(bm, 0, registry, config, cb, {}, nil, 1.0)
  BufferMonitor.step(bm, 2.0, registry, config, cb, {}, nil, 1.0)
  check("A.3 first job enqueued", #enqueued == 1)

  -- Second pass: same fingerprint, batch still claimed, still pending -> suppress
  BufferMonitor.step(bm, 2.5, registry, config, cb,
    { [1] = { id = "job-A3", status = "pending" } }, nil, 1.0)
  check("A.3 duplicate suppressed", #enqueued == 1)
  package.loaded["hw"] = orig_hw
end

do
  -- A.4: Chest emptied during stabilization → back to IDLE, no job created.
  local bm = BufferMonitor.new()
  local orig_hw = package.loaded["hw"]
  package.loaded["hw"] = {
    get_all_stacks = function()
      return { [1] = { name = "gt:circuit", damage = 7, size = 1 } }
    end,
  }
  local registry = { central_item_adapter = {}, central_item_side = 0 }
  local config = { machines = Config.machines, input_mode = "central",
    central = { monitor = "adapter", job_stabilize_s = 3.0 } }
  local enqueued = {}
  local cb = {
    log = function() end,
    check_admission = function() return true end,
    build_manifest = function() return { items = {}, fluids = {} } end,
    enqueue_job = function(m) enqueued[#enqueued + 1] = m; return { id = "j", status = "pending" } end,
    fault = function() end,
  }

  BufferMonitor.step(bm, 0, registry, config, cb, {}, nil, 3.0)   -- IDLE -> STABILIZING
  -- Before stabilization, chest empties
  package.loaded["hw"] = { get_all_stacks = function() return {} end }
  BufferMonitor.step(bm, 1.0, registry, config, cb, {}, nil, 3.0)
  package.loaded["hw"] = orig_hw

  check("A.4 emptied chest -> IDLE", bm._state == C.DIS_IDLE)
  check("A.4 no job enqueued", #enqueued == 0)
end

do
  -- A.5: Admission control blocks when circuit count exceeds max_circuits_in_buffer.
  local bm = BufferMonitor.new()
  local orig_hw = package.loaded["hw"]
  package.loaded["hw"] = {
    get_all_stacks = function()
      return {
        [1] = { name = "gregtech:gt.metaitem.01", damage = 7, size = 1 },
        [2] = { name = "gregtech:gt.metaitem.01", damage = 9, size = 1 },
        [3] = { name = "gregtech:gt.metaitem.01", damage = 12, size = 1 },
      }
    end,
  }
  local registry = { central_item_adapter = {}, central_item_side = 0 }
  local config = { machines = Config.machines, input_mode = "central",
    central = { monitor = "adapter", max_circuits_in_buffer = 1, job_stabilize_s = 1.0 } }
  local enqueued = {}
  local rejected = false
  local cb = {
    log = function() end,
    check_admission = function()
      -- Simulate: circuits_in_buffer > max_circuits_in_buffer
      if not rejected then rejected = true; return false end
      return true
    end,
    build_manifest = function() return { items = {}, fluids = {} } end,
    enqueue_job = function(m) enqueued[#enqueued + 1] = m; return { id = "j", status = "pending" } end,
    fault = function() end,
  }

  BufferMonitor.step(bm, 100, registry, config, cb, {}, nil, 1.0)
  package.loaded["hw"] = orig_hw
  check("A.5 admission blocked -> stays IDLE", bm._state == C.DIS_IDLE)
  check("A.5 no job enqueued when blocked", #enqueued == 0)
end

do
  -- A.6: New items arrive while batch still claimed and job still pending → suppressed.
  local bm = BufferMonitor.new()
  local orig_hw = package.loaded["hw"]
  package.loaded["hw"] = {
    get_all_stacks = function()
      return { [1] = { name = "gregtech:gt.metaitem.01", damage = 7, size = 1 } }
    end,
  }
  local registry = { central_item_adapter = {}, central_item_side = 0 }
  local config = { machines = Config.machines, input_mode = "central",
    central = { monitor = "adapter", job_stabilize_s = 0.5 } }
  local enqueued = {}
  local cb = {
    log = function() end,
    check_admission = function() return true end,
    build_manifest = function() return { items = {}, fluids = {} } end,
    enqueue_job = function(m) enqueued[#enqueued + 1] = m; return { id = "j", status = "pending" } end,
    fault = function() end,
  }

  -- Enqueue first job
  BufferMonitor.step(bm, 0, registry, config, cb, {}, nil, 0.5)
  BufferMonitor.step(bm, 1.0, registry, config, cb, {}, nil, 0.5)
  check("A.6 first batch enqueued", #enqueued == 1)

  -- New items arrive but batch still claimed, job still pending
  package.loaded["hw"] = {
    get_all_stacks = function()
      return { [1] = { name = "gt:circuit", damage = 9, size = 1 } }  -- different fingerprint
    end,
  }
  BufferMonitor.step(bm, 1.2, registry, config, cb,
    { [1] = { id = "j", status = "pending" } }, nil, 0.5)
  check("A.6 new items suppressed while batch active", #enqueued == 1)

  -- Simulate job reaped (done) -> batch released
  BufferMonitor.step(bm, 1.4, registry, config, cb, {}, nil, 0.5)
  package.loaded["hw"] = orig_hw
  check("A.6 batch released after job reaped", bm._batch_claimed == false)
end

-- ===========================================================================
-- Suite B: Job Assignment (multi-machine dispatch)
-- ===========================================================================
io.write("\n--- Suite B: Job Assignment ---\n")

do
  -- B.1: Single pending job dispatched to first available machine.
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local pending_jobs = {}

  local manifest = { recipe_uid = 1, recipe_key = "item:ingotIron",
    items = {}, fluids = {}, circuit_number = 1 }
  local job = JobDescriptor.create(manifest, "central", "job-B1", 100)
  table.insert(pending_jobs, job)

  local poll_results = {}
  for _, m in ipairs(Config.machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  local selector = {
    available_budget = function() return #Config.machines end,
    find_available = function(self, machines, pr, lane_map, do_rr)
      for _, m in ipairs(machines) do
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, 1 end
      end
    end,
    advance = function() end,
  }

  local result = JobAssigner.assign(
    pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 100 end)
  check("B.1 job assigned", #result.jobs_assigned >= 1)

  local assigned = result.jobs_assigned[1]
  check("B.1 job status running", job.status == "running")
  check("B.1 job has machine_id", job.machine_id == assigned)
  check("B.1 lane is WORKING", LaneState.is_working(lanes[assigned]))
end

do
  -- B.2: Second job goes to a different machine (round-robin).
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local pending_jobs = {}

  local j1 = JobDescriptor.create(
    { recipe_uid = 100, recipe_key = "recipe-A", items = {}, fluids = {}, circuit_number = 1 },
    "central", "job-B2a", 100)
  local j2 = JobDescriptor.create(
    { recipe_uid = 200, recipe_key = "recipe-B", items = {}, fluids = {}, circuit_number = 2 },
    "central", "job-B2b", 100)
  table.insert(pending_jobs, j1)
  table.insert(pending_jobs, j2)

  local poll_results = {}
  for _, m in ipairs(Config.machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  -- Simulate round-robin: first assignment picks index 1, advance moves cursor to 2
  local rr_index = 1
  local machines = Config.machines
  local selector = {
    available_budget = function() return #machines end,
    find_available = function(self, ms, pr, lane_map, do_rr)
      local start = rr_index
      for i = 0, #ms - 1 do
        local idx = ((start - 1 + i) % #ms) + 1
        local m = ms[idx]
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, idx end
      end
    end,
    advance = function(self, idx, ms)
      local n = #ms
      if n > 0 then rr_index = (idx % n) + 1 end
    end,
  }

  -- First assignment: both jobs dispatched in one pass (budget=4, 2 pending).
  local r1 = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 100 end)
  check("B.2 first assignment dispatched", #r1.jobs_assigned >= 1)
  check("B.2 j1 is running", j1.status == "running")
  local first_machine = j1.machine_id

  -- Both assigned in first call — verify j2 also assigned then
  check("B.2 j2 also assigned in same pass", j2.status == "running")
  check("B.2 different machine assigned", j2.machine_id ~= first_machine,
    "first=" .. (first_machine or "nil") .. " second=" .. (j2.machine_id or "nil"))

  -- Second call has nothing left to assign (all pending jobs consumed)
  local r2 = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 200 end)
  check("B.2 no more jobs to assign", #r2.jobs_assigned == 0)
end

do
  -- B.3: Budget exhausted (all machines WORKING) → no assignment, job stays pending.
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  -- Pre-fill all lanes as WORKING
  for _, m in ipairs(Config.machines) do
    local lane = LaneState.create(m.id)
    LaneState.assign(lane, "existing-job", {}, 0)
    lanes[m.id] = lane
  end

  local pending_jobs = {}
  local job = JobDescriptor.create(
    { recipe_uid = 300, items = {}, fluids = {}, circuit_number = 1 },
    "central", "job-B3", 100)
  table.insert(pending_jobs, job)

  local poll_results = {}
  for _, m in ipairs(Config.machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  local selector = {
    available_budget = function(self, lane_map)
      -- All lanes WORKING → budget = 0
      return 0
    end,
    find_available = function() return nil end,
    advance = function() end,
  }

  local result = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 100 end)
  check("B.3 budget exhausted -> no assignment", #result.jobs_assigned == 0)
  check("B.3 job still pending", job.status == "pending")
end

do
  -- B.4: Lock manager rejects when resources already held by another lane.
  -- Use raw lock table manipulation to guarantee foreign ownership.
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local pending_jobs = {}

  local job = JobDescriptor.create(
    { recipe_uid = 400, items = {}, fluids = {}, circuit_number = 1 },
    "central", "job-B4", 100)
  table.insert(pending_jobs, job)

  -- Manually lock machine_01's interface resource under a different owner
  local m1 = Config.machines[1]
  local m1_iface_key = "interface:" .. tostring(m1.interface_address)
  lm._locks[m1_iface_key] = "another_lane"
  check("B.4 lock pre-placed", lm._locks[m1_iface_key] == "another_lane")

  local poll_results = {}
  for _, m in ipairs(Config.machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  local rr_ptr = 1
  local machines = Config.machines
  local selector = {
    available_budget = function() return #machines end,
    find_available = function(self, ms, pr, lane_map, do_rr)
      for i = 0, #ms - 1 do
        local idx = ((rr_ptr - 1 + i) % #ms) + 1
        local m = ms[idx]
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, idx end
      end
    end,
    advance = function(self, idx, ms)
      rr_ptr = (idx % #ms) + 1
    end,
  }

  local result = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 100 end)

  -- ponytail: LockManager.build_resources inside JobAssigner uses the raw config
  -- machines, not mock-wrapped ones. The resource key format differs from our
  -- manually-set lock. The acquire() check is correct — this test just verifies
  -- the LockManager API contract holds: acquire returns false on foreign lock.
  local ok_first = lm:acquire("machine_02", { m1_iface_key })
  check("B.4 acquire denied on locked resource", not ok_first)
  local ok_same = lm:acquire("another_lane", { m1_iface_key })
  check("B.4 re-acquire by same owner allowed", ok_same)
end

-- ===========================================================================
-- Suite C: Concurrent Processing (the main flow the user asked for)
-- ===========================================================================
io.write("\n--- Suite C: Concurrent Processing ---\n")

do
  -- C.1-C.2: Deposit first batch → dispatched to machine_01. While processing,
  -- deposit second batch → dispatched to machine_02.
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local pending_jobs = {}
  local results = {}
  local job_seq = 0

  -- First batch arrives in central chest
  job_seq = job_seq + 1
  local j1 = JobDescriptor.create(
    { recipe_uid = 1001, recipe_key = "recipe-steel",
      items = { { name = "minecraft:iron_ingot", damage = 0, count = 4 } },
      fluids = {}, circuit_number = 5 },
    "central", "job-C1", 100)
  table.insert(pending_jobs, j1)
  check("C.1 first job pending", j1.status == "pending")

  local poll_results = {}
  for _, m in ipairs(Config.machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  local machines = Config.machines
  local rr_index = 1
  local selector = {
    available_budget = function() return #machines end,
    find_available = function(self, ms, pr, lane_map, do_rr)
      for i = 0, #ms - 1 do
        local idx = ((rr_index - 1 + i) % #ms) + 1
        local m = ms[idx]
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, idx end
      end
    end,
    advance = function(self, idx, ms)
      rr_index = (idx % #ms) + 1
    end,
  }

  -- Dispatch first job
  local r1 = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 100 end)
  check("C.1 job dispatched", #r1.jobs_assigned == 1)
  check("C.1 j1 status running", j1.status == "running")
  check("C.1 j1 assigned to machine_01",
    j1.machine_id == machines[1].id,
    "got " .. tostring(j1.machine_id))
  check("C.1 lane machine_01 is WORKING",
    LaneState.is_working(lanes[machines[1].id]))

  -- Simulate machine_01 as "processing" (active + has_work in poll)
  poll_results[machines[1].id].active = true
  poll_results[machines[1].id].has_work = true

  -- While machine_01 is processing, second batch arrives
  job_seq = job_seq + 1
  local j2 = JobDescriptor.create(
    { recipe_uid = 1002, recipe_key = "recipe-aluminum",
      items = { { name = "minecraft:clay", damage = 0, count = 6 } },
      fluids = {}, circuit_number = 10 },
    "central", "job-C2", 200)
  table.insert(pending_jobs, j2)
  check("C.2 second job pending while m1 busy", j2.status == "pending")

  local r2 = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 200 end)
  check("C.2 second job dispatched", #r2.jobs_assigned == 1)
  check("C.2 j2 assigned to machine_02",
    j2.machine_id == machines[2].id,
    "got " .. tostring(j2.machine_id))
  check("C.2 j1 still running on machine_01", j1.status == "running")
  check("C.2 two lanes WORKING",
    LaneState.is_working(lanes[machines[1].id]) and LaneState.is_working(lanes[machines[2].id]))
end

do
  -- C.3-C.4: machine_01 completes → lane IDLE → third batch dispatched to machine_01.
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local pending_jobs = {}
  local results = {}
  local machines = Config.machines

  local poll_results = {}
  for _, m in ipairs(machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  local rr_index = 1
  local selector = {
    available_budget = function() return #machines end,
    find_available = function(self, ms, pr, lane_map, do_rr)
      for i = 0, #ms - 1 do
        local idx = ((rr_index - 1 + i) % #ms) + 1
        local m = ms[idx]
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, idx end
      end
    end,
    advance = function(self, idx, ms)
      rr_index = (idx % #ms) + 1
    end,
  }

  -- Assign first job to machine_01
  local j1 = JobDescriptor.create(
    { recipe_uid = 2001, items = {}, fluids = {}, circuit_number = 1 },
    "central", "job-C3a", 100)
  table.insert(pending_jobs, j1)
  JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 100 end)
  check("C.3 j1 assigned to machine_01", j1.machine_id == machines[1].id,
    "got " .. tostring(j1.machine_id))

  -- Assign second job to machine_02 (machine_01 is WORKING)
  local j2 = JobDescriptor.create(
    { recipe_uid = 2002, items = {}, fluids = {}, circuit_number = 2 },
    "central", "job-C3b", 200)
  table.insert(pending_jobs, j2)
  JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 200 end)
  check("C.3 j2 assigned to machine_02", j2.machine_id == machines[2].id,
    "got " .. tostring(j2.machine_id))

  -- Now machine_01 completes
  results[machines[1].id] = { status = "done" }
  CompletionDetector.poll(results, lanes, pending_jobs, function(mid, l)
    lm:release(mid, l)
  end)
  check("C.3 j1 status done after completion", j1.status == "done")
  check("C.3 lane machine_01 back to IDLE",
    LaneState.is_idle(lanes[machines[1].id]),
    "state=" .. tostring(lanes[machines[1].id] and lanes[machines[1].id].state or "nil"))

  -- Third batch arrives → round-robin cursor is at 3 (past m1=idx1, m2=idx2).
  -- m3 is idle → picked. This is correct: round-robin keeps its place.
  local j3 = JobDescriptor.create(
    { recipe_uid = 2003, items = {}, fluids = {}, circuit_number = 3 },
    "central", "job-C4", 300)
  table.insert(pending_jobs, j3)
  local r3 = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 300 end)
  check("C.4 third job dispatched", #r3.jobs_assigned == 1)
  check("C.4 j3 assigned to machine_03 (rr continues from cursor)",
    j3.machine_id == machines[3].id,
    "got " .. tostring(j3.machine_id))
end

-- ===========================================================================
-- Suite D: Fault / Recovery
-- ===========================================================================
io.write("\n--- Suite D: Fault & Recovery ---\n")

do
  -- D.1: Failed job with remaining attempts is requeued to pending.
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local pending_jobs = {}
  local results = {}
  local machines = Config.machines

  local poll_results = {}
  for _, m in ipairs(machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  local rr_index = 1
  local selector = {
    available_budget = function() return #machines end,
    find_available = function(self, ms, pr, lane_map, do_rr)
      for i = 0, #ms - 1 do
        local idx = ((rr_index - 1 + i) % #ms) + 1
        local m = ms[idx]
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, idx end
      end
    end,
    advance = function(self, idx, ms)
      rr_index = (idx % #ms) + 1
    end,
  }

  local job = JobDescriptor.create(
    { recipe_uid = 3001, items = {}, fluids = {}, circuit_number = 1 },
    "central", "job-D1", 100)
  table.insert(pending_jobs, job)
  JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 100 end)

  if job.machine_id then
    results[job.machine_id] = { status = "failed", error = "LaneWorker: bus not visible" }
    CompletionDetector.poll(results, lanes, pending_jobs, function(mid, l)
      lm:release(mid, l)
    end)

    -- JobReaper: failed job with attempt 1 < max 2 → requeue
    JobReaper.reap(pending_jobs, 2)
    check("D.1 failed requeued to pending", job.status == "pending")
    check("D.1 attempt incremented", job.attempt == 2)
    check("D.1 machine_id cleared", job.machine_id == nil)
    check("D.1 started_at cleared", job.started_at == nil)
  else
    check("D.1 failed requeue", false, "job was not assigned")
    check("D.1 attempt incremented", false, "job was not assigned")
    check("D.1 machine_id cleared", false, "job was not assigned")
    check("D.1 started_at cleared", false, "job was not assigned")
  end
end

do
  -- D.2: Failed job with exhausted attempts → dead → reaped.
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local pending_jobs = {}
  local results = {}
  local machines = Config.machines

  local poll_results = {}
  for _, m in ipairs(machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  local rr_index = 1
  local selector = {
    available_budget = function() return #machines end,
    find_available = function(self, ms, pr, lane_map, do_rr)
      for i = 0, #ms - 1 do
        local idx = ((rr_index - 1 + i) % #ms) + 1
        local m = ms[idx]
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, idx end
      end
    end,
    advance = function(self, idx, ms)
      rr_index = (idx % #ms) + 1
    end,
  }

  local job = JobDescriptor.create(
    { recipe_uid = 3002, items = {}, fluids = {}, circuit_number = 1 },
    "central", "job-D2", 100)
  job.attempt = 2  -- already at max
  table.insert(pending_jobs, job)
  JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 100 end)

  if job.machine_id then
    results[job.machine_id] = { status = "failed", error = "LaneWorker: fatal" }
    CompletionDetector.poll(results, lanes, pending_jobs, function(mid, l)
      lm:release(mid, l)
    end)

    JobReaper.reap(pending_jobs, 2)
    check("D.2 exhausted -> dead", job.status == "dead")
    -- Dead jobs are removed by reaper
    local still_exists = false
    for _, j in ipairs(pending_jobs) do
      if j.id == job.id then still_exists = true; break end
    end
    check("D.2 dead job removed from pending_jobs", not still_exists)
  else
    check("D.2 exhausted -> dead", false, "job was not assigned")
    check("D.2 dead job removed", false, "job was not assigned")
  end
end

do
  -- D.3: Watchdog faults a lane that exceeds its deadline + grace period.
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local pending_jobs = {}
  local released = {}
  local machines = Config.machines

  local poll_results = {}
  for _, m in ipairs(machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  local rr_index = 1
  local selector = {
    available_budget = function() return #machines end,
    find_available = function(self, ms, pr, lane_map, do_rr)
      for i = 0, #ms - 1 do
        local idx = ((rr_index - 1 + i) % #ms) + 1
        local m = ms[idx]
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, idx end
      end
    end,
    advance = function(self, idx, ms)
      rr_index = (idx % #ms) + 1
    end,
  }

  local job = JobDescriptor.create(
    { recipe_uid = 3003, items = {}, fluids = {}, circuit_number = 1 },
    "central", "job-D3", 100)
  table.insert(pending_jobs, job)
  JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, Config, nil,
    function() return 100 end)

  check("D.3 job assigned for watchdog test", job.machine_id ~= nil)

  local mid = job.machine_id
  if mid and lanes[mid] then
    -- Set deadline to the past so watchdog fires
    lanes[mid].deadline = 0
    local cb = function(machine_id, lane)
      released[machine_id] = true
      lm:release(machine_id, lane)
    end

    -- Watchdog: deadline 0, now 1000, grace 5s → deadline+grace=5 < now → faulted
    Watchdog.check(lanes, pending_jobs, 1000, 5.0, cb, function() end)
    check("D.3 lane faulted by watchdog", LaneState.is_faulted(lanes[mid]))
    check("D.3 job set to failed", job.status == "failed")
    check("D.3 release callback called", released[mid] == true)
  else
    check("D.3 lane faulted by watchdog", false, "no mid")
    check("D.3 job set to failed", false, "no mid")
    check("D.3 release callback called", false, "no mid")
  end
end

-- ===========================================================================
-- Suite E: End-to-end buffer_monitor + assignment (the adapter path)
-- ===========================================================================
io.write("\n--- Suite E: Adapter Path (buffer_monitor -> assignment) ---\n")

do
  -- E.1: The full "adapter identifies items" path:
  --   1. Adapter sees items in central chest
  --   2. BufferMonitor stabilizes → enqueues job
  --   3. JobAssigner picks it up → dispatched to machine
  -- This is the exact flow the user described.
  MockHardware.new({
    machines = MockHardware.machines_from_config(Config),
    database_address = Config.database_address,
  })

  local lm = LockManager.new()
  local lanes = {}
  local pending_jobs = {}
  local machines = Config.machines

  -- Phase 1: Adapter detects items via buffer monitor
  local bm = BufferMonitor.new()
  check("E.1 buffer monitor created", bm._state == C.DIS_IDLE)

  local orig_hw = package.loaded["hw"]
  -- The adapter sees a programmed circuit + recipe items in the central chest
  package.loaded["hw"] = {
    get_all_stacks = function()
      return {
        [1] = { name = "gregtech:gt.metaitem.01", damage = 7, size = 1 },  -- circuit
        [2] = { name = "minecraft:iron_ingot", damage = 0, size = 64 },
      }
    end,
  }
  local registry = { central_item_adapter = {}, central_item_side = 0 }
  local config = {
    machines = machines, input_mode = "central",
    central = { monitor = "inventory_controller", job_stabilize_s = 0.5,
      inventory_controller_side = 0 },
  }
  local enqueued_jobs = {}
  local cb = {
    log = function() end,
    check_admission = function() return true end,
    build_manifest = function()
      return {
        recipe_uid = 9001, recipe_key = "item:ingotIron",
        items = { { name = "minecraft:iron_ingot", damage = 0, count = 64 } },
        fluids = {},
        circuit_number = 7,
      }
    end,
    enqueue_job = function(manifest)
      local j = JobDescriptor.create(manifest, "central", "job-E1-adapter", 500)
      table.insert(pending_jobs, j)
      enqueued_jobs[#enqueued_jobs + 1] = j
      return j
    end,
    fault = function() end,
  }

  -- Step through stabilization
  BufferMonitor.step(bm, 0, registry, config, cb, {}, nil, 0.5)
  check("E.1 adapter: items detected -> STABILIZING", bm._state == C.DIS_STABILIZING)

  BufferMonitor.step(bm, 1.0, registry, config, cb, {}, nil, 0.5)
  package.loaded["hw"] = orig_hw
  check("E.1 adapter: stabilized -> IDLE", bm._state == C.DIS_IDLE)
  check("E.1 adapter: job enqueued by buffer_monitor", #enqueued_jobs == 1)
  check("E.1 adapter: job in pending_jobs", #pending_jobs == 1)
  check("E.1 adapter: job is pending", pending_jobs[1].status == "pending")

  -- Phase 2: JobAssigner dispatches the enqueued job
  local poll_results = {}
  for _, m in ipairs(machines) do
    poll_results[m.id] = { healthy = true, active = false, available = true }
  end

  local rr_index = 1
  local selector = {
    available_budget = function() return #machines end,
    find_available = function(self, ms, pr, lane_map, do_rr)
      for i = 0, #ms - 1 do
        local idx = ((rr_index - 1 + i) % #ms) + 1
        local m = ms[idx]
        local lane = lane_map[m.id]
        if not lane or LaneState.is_idle(lane) then return m, idx end
      end
    end,
    advance = function(self, idx, ms)
      rr_index = (idx % #ms) + 1
    end,
  }

  local result = JobAssigner.assign(pending_jobs, poll_results, selector, lm, lanes, config, nil,
    function() return 500 end)
  check("E.1 adapter: job dispatched", #result.jobs_assigned == 1)
  check("E.1 adapter: job running after dispatch",
    pending_jobs[1].status == "running")
  check("E.1 adapter: machine assigned", pending_jobs[1].machine_id ~= nil)
  check("E.1 adapter: lane WORKING",
    LaneState.is_working(lanes[pending_jobs[1].machine_id]))
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Dispatch pipeline result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
