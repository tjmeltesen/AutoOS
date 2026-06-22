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
    wait = { type = "ready" },
    dead = false,
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
    task.dead = true
    self.log(string.format("[Scheduler] %s coroutine was dead before resume", task.name))
    return
  end
  local ok, spec = coroutine.resume(task.co, ...)
  if not ok then
    task.dead = true
    local tb = debug and debug.traceback and debug.traceback(tostring(spec), 2) or ""
    self.log(string.format("[Scheduler] task %s FAILED: %s\n%s", task.name, tostring(spec), tb))
    local alive = 0; for _, t in ipairs(self.tasks) do if not t.dead then alive = alive + 1 end end
    self.log(string.format("[Scheduler] %d tasks still alive after %s failure", alive, task.name))
    return
  end
  if coroutine.status(task.co) == "dead" then
    task.dead = true
    self.log(string.format("[Scheduler] task %s completed (coroutine dead)", task.name))
    return
  end
  task.wait = normalize_wait(spec, self:now())
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
