--[[
  AutoOS — OC event API mock
  Models: event.pull(timeout), event.push(name, ...), event.listen(), event.ignore()

  Usage:
    local mock_event = OCEventMock.new()
    mock_event.push("modem_message", nil, nil, "addr", 105, 10, "hello")
    local _, _, from, port, distance, msg = mock_event.pull(0)
]]

local unpack = table.unpack or unpack

local OCEventMock = {}

function OCEventMock.new(opts)
  opts = opts or {}
  local self = {
    _queue = opts.queue or {},
    _filters = {},
    _call_counts = { pull = 0, push = 0, listen = 0, ignore = 0 },
  }
  -- Copy initial queue items
  if opts.queue then
    for i = 1, #opts.queue do
      self._queue[i] = {}
      for j = 1, #opts.queue[i] do
        self._queue[i][j] = opts.queue[i][j]
      end
    end
  end
  setmetatable(self, { __index = OCEventMock })
  return self
end

--- event.pull(timeout?, filter...) -> event_id, ...
function OCEventMock.pull(self, timeout, ...)
  self._call_counts.pull = self._call_counts.pull + 1
  local filters = { ... }

  for i = 1, #self._queue do
    local evt = self._queue[i]
    if #filters == 0 then
      table.remove(self._queue, i)
      return unpack(evt)
    end
    -- Match first filter (event name)
    for _, f in ipairs(filters) do
      if type(f) == "string" and evt[1] == f then
        table.remove(self._queue, i)
        return unpack(evt)
      end
    end
  end
  return nil
end

--- Push an event onto the queue
function OCEventMock.push(self, ...)
  self._call_counts.push = self._call_counts.push + 1
  self._queue[#self._queue + 1] = { ... }
end

--- event.listen(name) — start intercepting
function OCEventMock.listen(self, name)
  self._call_counts.listen = self._call_counts.listen + 1
  self._filters[name] = true
end

--- event.ignore(name) — stop intercepting
function OCEventMock.ignore(self, name)
  self._call_counts.ignore = self._call_counts.ignore + 1
  self._filters[name] = nil
end

function OCEventMock.is_listening(self, name)
  return self._filters[name] == true
end

function OCEventMock.queue_length(self)
  return #self._queue
end

function OCEventMock.get_call_counts(self)
  return self._call_counts
end

return OCEventMock
