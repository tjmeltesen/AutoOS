#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/unit/buffer_monitor_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_core" .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "rob_services" .. sep .. "?.lua",
  package.path,
}, ";")

local C = require("rob_core.constants")
local BufferMonitor = require("buffer_monitor")

local ESC = string.char(27)
local function color(c, t) return ESC .. "[" .. c .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write("  -  " .. tostring(detail)) end
  io.write("\n")
end

-- Minimal registry stub for testing
local function make_registry(opts)
  opts = opts or {}
  return {
    central_item_adapter = opts.adapter or {},
    central_item_side = opts.side or 0,
  }
end

local function make_config(opts)
  opts = opts or {}
  return {
    machines = opts.machines or {},
    completion_timeout_s = opts.completion_timeout_s or 60,
    staging_timeout_s = opts.staging_timeout_s or 60,
    do_round_robin = opts.do_round_robin ~= false,
    input_mode = opts.input_mode or "central",
    central = opts.central or { monitor = "adapter" },
  }
end

local function make_callbacks(opts)
  opts = opts or {}
  local logs = {}
  local function log_fn(msg) logs[#logs + 1] = msg end
  return {
    log = log_fn,
    check_admission = opts.check_admission or function() return true end,
    build_manifest = opts.build_manifest or function() return { items = {} } end,
    enqueue_job = opts.enqueue_job or function(manifest)
      return { id = "job_" .. tostring(#logs), status = "pending" }
    end,
    fault = opts.fault or function() end,
    logs = logs,
  }
end

io.write("\n" .. bold("BufferMonitor Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local bm = BufferMonitor.new()
  check("new creates IDLE state", bm._state == C.DIS_IDLE)
  check("new has nil fingerprint", bm._fingerprint == nil)
  check("new stable_since is 0", bm._stable_since == 0)
  check("new has nil last_enqueued_fp", bm._last_enqueued_fp == nil)
  check("new batch_claimed is false", bm._batch_claimed == false)
end

do
  -- Without adapter, step returns no events and stays IDLE
  local bm = BufferMonitor.new()
  local registry = make_registry({ adapter = nil })
  local config = make_config()
  local cb = make_callbacks()
  local result = BufferMonitor.step(bm, 100, registry, config, cb, {}, nil, 3.0)
  check("no adapter returns empty events", #result.events == 0)
end

do
  -- Admission rejection keeps IDLE with no events
  local bm = BufferMonitor.new()
  local registry = make_registry({ adapter = {} })
  local config = make_config()
  -- Mock HW.get_all_stacks to return items
  -- BufferMonitor.build_fingerprint calls require("hw") internally.
  -- We need to override it. Since the module calls require("hw") internally,
  -- we stub it via package.loaded.
  local orig_hw = package.loaded["hw"]
  package.loaded["hw"] = {
    get_all_stacks = function() return { [1] = { name = "item:ingotIron", size = 64 } } end,
  }

  local cb = make_callbacks({ check_admission = function() return false end })
  local result = BufferMonitor.step(bm, 100, registry, config, cb, {}, nil, 3.0)

  package.loaded["hw"] = orig_hw
  -- With items present but admission rejected, stays IDLE
  check("admission rejection stays IDLE", bm._state == C.DIS_IDLE)
  check("admission rejection returns no events", #result.events == 0)
end

do
  -- When adapter has items and admission passes, moves to STABILIZING
  local bm = BufferMonitor.new()
  local registry = make_registry({ adapter = {} })
  local config = make_config()
  local orig_hw = package.loaded["hw"]
  package.loaded["hw"] = {
    get_all_stacks = function() return { [1] = { name = "item:ingotIron", size = 64 } } end,
  }

  local cb = make_callbacks()
  local result = BufferMonitor.step(bm, 100, registry, config, cb, {}, nil, 3.0)

  package.loaded["hw"] = orig_hw
  check("items detected moves to STABILIZING", bm._state == C.DIS_STABILIZING)
  check("stable_since set", bm._stable_since == 100)
  check("event emitted for central_buffer_ready", #result.events >= 1)
end

do
  -- Stabilization completes after timeout, enqueues job
  local bm = BufferMonitor.new()
  local registry = make_registry({ adapter = {} })
  local config = make_config()
  local orig_hw = package.loaded["hw"]
  local stacks = { [1] = { name = "item:ingotIron", size = 64 } }
  package.loaded["hw"] = {
    get_all_stacks = function() return stacks end,
  }

  local cb = make_callbacks()
  -- First step: IDLE -> STABILIZING
  BufferMonitor.step(bm, 0, registry, config, cb, {}, nil, 3.0)
  check("after first step: STABILIZING", bm._state == C.DIS_STABILIZING)

  -- Second step: still stabilizing (0.1s elapsed, need 3.0s)
  BufferMonitor.step(bm, 0.1, registry, config, cb, {}, nil, 3.0)
  check("0.1s: still STABILIZING", bm._state == C.DIS_STABILIZING)

  -- Third step: stabilized (4.0s elapsed)
  BufferMonitor.step(bm, 4.0, registry, config, cb, {}, nil, 3.0)
  package.loaded["hw"] = orig_hw

  check("4.0s: transitioned to IDLE", bm._state == C.DIS_IDLE)
  check("batch_claimed set", bm._batch_claimed == true)
  check("batch_job_id set", bm._batch_job_id ~= nil)
end

do
  -- Chest emptied during stabilization -> back to IDLE
  local bm = BufferMonitor.new()
  local registry = make_registry({ adapter = {} })
  local config = make_config()
  local orig_hw = package.loaded["hw"]

  -- First call: has items
  package.loaded["hw"] = {
    get_all_stacks = function() return { [1] = { name = "item:ingotIron", size = 64 } } end,
  }
  local cb = make_callbacks()
  BufferMonitor.step(bm, 0, registry, config, cb, {}, nil, 3.0)
  -- Second call: emptied
  package.loaded["hw"] = {
    get_all_stacks = function() return {} end,
  }
  BufferMonitor.step(bm, 1.0, registry, config, cb, {}, nil, 3.0)

  package.loaded["hw"] = orig_hw
  check("chest emptied resets to IDLE", bm._state == C.DIS_IDLE)
  check("batch_claimed cleared", bm._batch_claimed == false)
end

do
  -- Fingerprint change during stabilization resets timer
  local bm = BufferMonitor.new()
  local registry = make_registry({ adapter = {} })
  local config = make_config()
  local orig_hw = package.loaded["hw"]

  package.loaded["hw"] = {
    get_all_stacks = function() return { [1] = { name = "item:ingotIron", size = 64 } } end,
  }
  local cb = make_callbacks()

  -- Step 1: IDLE -> STABILIZING with fingerprint A
  BufferMonitor.step(bm, 0, registry, config, cb, {}, nil, 3.0)

  -- Step 2: fingerprint changed
  package.loaded["hw"] = {
    get_all_stacks = function() return { [1] = { name = "item:ingotIron", size = 64 }, [2] = { name = "item:ingotGold", size = 32 } } end,
  }
  BufferMonitor.step(bm, 1.0, registry, config, cb, {}, nil, 3.0)

  package.loaded["hw"] = orig_hw
  check("fingerprint change resets stable_since", bm._stable_since == 1.0)
  check("still STABILIZING after fp change", bm._state == C.DIS_STABILIZING)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("BufferMonitor result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
