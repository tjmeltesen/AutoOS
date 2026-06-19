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
  if task.dead then return end
  local ok, spec = coroutine.resume(task.co, ...)
  if not ok then
    task.dead = true
    self.log(string.format("[Scheduler] task %s failed: %s", task.name, tostring(spec)))
    return
  end
  if coroutine.status(task.co) == "dead" then
    task.dead = true
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
  for _, task in ipairs(self.tasks) do
    if not task.dead then
      local wait = task.wait or { type = "ready" }
      if wait.type == "ready" or (wait.type == "sleep" and (wait.deadline or now) <= now) then
        self:_resume(task)
      end
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
  while self._running and self:has_live_tasks() do
    self:_resume_due()
    local timeout = self:_next_timeout()
    local ev = { self.event.pull(timeout) }
    if ev[1] ~= nil then self:_dispatch_event(ev) end
    cycles = cycles + 1
    if max_cycles and cycles >= max_cycles then break end
  end
end

return Scheduler
