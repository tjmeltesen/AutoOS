--[[
  AutoOS - tiny cooperative coroutine scheduler.

  Tasks yield declarative wait specs:
    { type = "sleep", seconds = 0.1 }
    { type = "event", filter = "modem_message" } -- or predicate function
    { type = "yield" }
]]

local Scheduler = {}
Scheduler.__index = Scheduler

local unpack = table.unpack or unpack

function Scheduler.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Scheduler)
  self.event = deps.event or require("event")
  self.computer = deps.computer or require("computer")
  self.log = deps.log or function() end
  self.tasks = {}
  self._seq = 0
  self._running = false
  self._resume_call_count = 0
  -- Fault capture callback: function(tag, err, extra) called when a task crashes.
  -- Injected by bootstrap to wire to fault_net.capture.
  self._fault_capture = deps.fault_capture
  return self
end

function Scheduler:now()
  return self.computer.uptime()
end

function Scheduler:spawn(name, fn)
  self._seq = self._seq + 1
  local task = {
    id = self._seq,
    name = name or ("task_" .. tostring(self._seq)),
    co = coroutine.create(fn),
    factory = fn,  -- stored so we can re-create the coroutine on crash
    wait = { type = "ready" },
    dead = false,
    fault_count = 0,
  }
  self.tasks[#self.tasks + 1] = task
  self.log(string.format("[Scheduler] spawned task %d: %s", self._seq, name))
  return task
end

function Scheduler:wake(name)
  for _, task in ipairs(self.tasks) do
    if not task.dead and task.name == name then
      task.wait = { type = "ready" }
      return true
    end
  end
  -- Diagnostic: log known task names on first miss per name
  if not self._wake_misses then self._wake_misses = {} end
  if not self._wake_misses[name] then
    self._wake_misses[name] = true
    local known = {}
    for _, task in ipairs(self.tasks) do
      if not task.dead and task.name then
        known[#known + 1] = task.name
      end
    end
    self.log(string.format("[Scheduler] wake MISS: %q not found — known tasks: %s",
      tostring(name), #known > 0 and table.concat(known, ",") or "(none)"))
  end
  return false
end

function Scheduler:wake_prefix(prefix)
  local n = 0
  for _, task in ipairs(self.tasks) do
    if not task.dead and task.name and task.name:sub(1, #prefix) == prefix then
      task.wait = { type = "ready" }
      n = n + 1
    end
  end
  return n
end

function Scheduler.sleep(seconds)
  return coroutine.yield({ type = "sleep", seconds = seconds or 0 })
end

function Scheduler.wait_event(filter)
  return coroutine.yield({ type = "event", filter = filter })
end

function Scheduler.yield_now()
  return coroutine.yield({ type = "yield" })
end

function Scheduler:stop()
  self._running = false
end

--- Mark all tasks dead and clear the task list. Safe to call from any context.
--- Used by broker shutdown to release all coroutines before restart.
function Scheduler:clear()
  for _, task in ipairs(self.tasks) do
    task.dead = true
  end
  self.tasks = {}
  self._running = false
end

local function normalize_wait(spec, now)
  if spec == nil then
    return { type = "ready" }
  end
  if type(spec) ~= "table" then
    return { type = "ready" }
  end
  if spec.type == "sleep" then
    return { type = "sleep", deadline = now + math.max(0, spec.seconds or 0) }
  end
  if spec.type == "event" then
    return { type = "event", filter = spec.filter }
  end
  if spec.type == "yield" then
    return { type = "sleep", deadline = now }
  end
  return spec
end

function Scheduler:_resume(task, ...)
  if task.dead then
    self.log(string.format("[Scheduler] SKIP %s (dead)", task.name))
    return
  end
  if coroutine.status(task.co) == "dead" then
    -- Coroutine died without us catching the error (shouldn't happen normally,
    -- but can occur if the coroutine returned normally or was killed externally).
    if task.factory then
      -- Re-create: silently restart tasks that exit cleanly
      task.co = coroutine.create(task.factory)
      task.wait = { type = "ready" }
      self.log(string.format("[Scheduler] %s coroutine was dead — re-created", task.name))
      return
    end
    task.dead = true
    self.log(string.format("[Scheduler] %s coroutine was dead before resume, no factory", task.name))
    return
  end
  local ok, spec = coroutine.resume(task.co, ...)
  if not ok then
    -- Task crashed.  Build traceback, capture via fault_net, and re-create
    -- the coroutine so the task survives (don't mark dead).
    local err_msg = tostring(spec)
    local tb = (debug and debug.traceback and debug.traceback(err_msg, 2)) or err_msg
    self.log(string.format("[Scheduler] task %s FAULT: %s", task.name, tb))

    -- Increment fault counter for backoff
    task.fault_count = (task.fault_count or 0) + 1

    -- Capture via fault_net callback if wired
    if self._fault_capture then
      local tag = "task." .. tostring(task.name)
      local extra = { fault_n = task.fault_count }
      self._fault_capture(tag, tb, extra)
    end

    -- Re-create the coroutine so the task keeps running
    if task.factory then
      task.co = coroutine.create(task.factory)
      -- Backoff: if crashing rapidly, add a small delay
      if task.fault_count > 5 then
        task.wait = { type = "sleep", deadline = self:now() + math.min(30, task.fault_count) }
      else
        task.wait = { type = "ready" }
      end
    else
      task.dead = true
      self.log(string.format("[Scheduler] task %s unrecoverable — no factory to re-create", task.name))
    end
    return
  end
  if coroutine.status(task.co) == "dead" then
    -- Coroutine completed normally (returned).  Re-create if we have a factory.
    if task.factory then
      task.co = coroutine.create(task.factory)
      task.wait = { type = "ready" }
      self.log(string.format("[Scheduler] task %s completed — re-created", task.name))
      return
    end
    task.dead = true
    self.log(string.format("[Scheduler] task %s completed (coroutine dead, no factory)", task.name))
    return
  end
  task.wait = normalize_wait(spec, self:now())
  -- Reset fault count on successful execution
  if task.fault_count and task.fault_count > 0 then
    task.fault_count = 0
  end
end

local function event_matches(filter, ev)
  if filter == nil then return true end
  if type(filter) == "string" then return ev[1] == filter end
  if type(filter) == "function" then return filter(unpack(ev)) end
  if type(filter) == "table" then
    for _, name in ipairs(filter) do
      if ev[1] == name then return true end
    end
  end
  return false
end

function Scheduler:_next_timeout()
  local now = self:now()
  local any_ready = false
  local next_deadline = nil
  for _, task in ipairs(self.tasks) do
    if not task.dead then
      local wait = task.wait or { type = "ready" }
      if wait.type == "ready" then
        any_ready = true
      elseif wait.type == "sleep" then
        if (wait.deadline or now) <= now then
          any_ready = true
        elseif not next_deadline or wait.deadline < next_deadline then
          next_deadline = wait.deadline
        end
      end
    end
  end
  if any_ready then return 0 end
  if next_deadline then return math.max(0, next_deadline - now) end
  return nil
end

function Scheduler:_resume_due()
  local now = self:now()
  local resumed = {}
  for _, task in ipairs(self.tasks) do
    if not task.dead then
      local wait = task.wait or { type = "ready" }
      if wait.type == "ready" or (wait.type == "sleep" and (wait.deadline or now) <= now) then
        self:_resume(task)
        resumed[#resumed + 1] = task.name
      end
    end
  end
  if #resumed > 0 and self._resume_call_count then
    self._resume_call_count = self._resume_call_count + 1
    if self._resume_call_count % 10 == 1 then
      self.log(string.format("[Scheduler] _resume_due #%d: resumed=%s",
        self._resume_call_count, table.concat(resumed, ",")))
    end
  end
end

function Scheduler:_dispatch_event(ev)
  for _, task in ipairs(self.tasks) do
    if not task.dead and task.wait and task.wait.type == "event" and event_matches(task.wait.filter, ev) then
      self:_resume(task, unpack(ev))
    end
  end
end

function Scheduler:has_live_tasks()
  for _, task in ipairs(self.tasks) do
    if not task.dead then return true end
  end
  return false
end

function Scheduler:run(max_cycles)
  self._running = true
  local cycles = 0
  local live = 0; for _, t in ipairs(self.tasks) do if not t.dead then live = live + 1 end end
  self.log(string.format("[Scheduler] run START — %d tasks (%d live)", #self.tasks, live))
  while self._running and self:has_live_tasks() do
    self:_resume_due()
    local timeout = self:_next_timeout()
    local ev = { self.event.pull(timeout) }
    if ev[1] ~= nil then self:_dispatch_event(ev) end
    cycles = cycles + 1
    if max_cycles and cycles >= max_cycles then
      self.log(string.format("[Scheduler] run STOP — max_cycles=%d reached after %d cycles", max_cycles, cycles))
      break
    end
  end
  self.log(string.format("[Scheduler] run EXIT — running=%s has_live=%s cycles=%d",
    tostring(self._running), tostring(self:has_live_tasks()), cycles))
end

return Scheduler
