--[[
  AutoOS — Fault Net
  Centralized fault capture so no runtime error is silent.

  capture(ctx, tag, err, extra?)
    Timestamped [FAULT] line to ctx.log (fallback print).
    Appends to in-memory ring buffer ctx.faults.items.
    Best-effort append to /home/subnet_broker/fault.log.

  guard(ctx, tag, fn, ...)
    Executes fn(...) under xpcall with debug.traceback.
    On error: calls capture, returns (false, traceback_string).
    On success: returns (true, result).
]]

local FaultNet = {}

-- Max lines kept in the in-memory ring buffer.
local RING_MAX = 100

-- Path for persistent fault log on the OC filesystem.
local FAULT_LOG_PATH = "/home/subnet_broker/fault.log"
local _file_write_count = 0
local _MAX_FILE_LINES = 500  -- rotate after this many writes

---------------------------------------------------------------------------
-- Internal: build a timestamp string (OC-compatible).
-- Uses os.date if available; falls back to os.time.
---------------------------------------------------------------------------
local function _timestamp()
  local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  if ok and type(s) == "string" then return s end
  return tostring(os.time and os.time() or 0)
end

---------------------------------------------------------------------------
-- Internal: append one line to the persistent fault log.
-- Rotates (truncates) after MAX_FILE_LINES writes to bound disk usage.
---------------------------------------------------------------------------
local function _file_append(line)
  _file_write_count = _file_write_count + 1
  local mode = "a"
  if _file_write_count > _MAX_FILE_LINES then
    _file_write_count = 1
    mode = "w"
  end
  local f = io.open(FAULT_LOG_PATH, mode)
  if f then
    f:write(line .. "\n")
    f:close()
  end
end

---------------------------------------------------------------------------
-- Ensure ctx.faults ring buffer exists.
---------------------------------------------------------------------------
local function _ensure_ring(ctx)
  if not ctx.faults then
    ctx.faults = { items = {}, head = 1, count = 0, max = RING_MAX }
  end
  local f = ctx.faults
  if not f.items then f.items = {} end
  if not f.max then f.max = RING_MAX end
  if not f.head then f.head = 1 end
  if not f.count then f.count = 0 end
  return f
end

---------------------------------------------------------------------------
-- Append to the in-memory ring buffer.
---------------------------------------------------------------------------
local function _ring_append(ring, entry)
  local idx = ring.head
  ring.items[idx] = entry
  ring.head = (idx % ring.max) + 1
  ring.count = math.min(ring.count + 1, ring.max)
end

---------------------------------------------------------------------------
-- capture(ctx, tag, err, extra?)
--   tag   - stable identifier like "task.central_dispatch"
--   err   - error message or traceback string
--   extra - optional table merged into the log line (port, sender, etc.)
---------------------------------------------------------------------------
function FaultNet.capture(ctx, tag, err, extra)
  local ts = _timestamp()
  local log = (ctx and ctx.log) or print
  local err_str = tostring(err or "(unknown)")

  -- Build extra portion
  local extra_str = ""
  if type(extra) == "table" then
    local parts = {}
    for k, v in pairs(extra) do
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
    if #parts > 0 then
      extra_str = " " .. table.concat(parts, " ")
    end
  elseif extra ~= nil then
    extra_str = " " .. tostring(extra)
  end

  local line = string.format("[FAULT] %s %s %s%s", ts, tostring(tag), err_str, extra_str)

  -- Console
  log(line)

  -- Ring buffer
  if ctx then
    local ring = _ensure_ring(ctx)
    _ring_append(ring, { ts = ts, tag = tostring(tag), err = err_str, extra = extra })
  end

  -- Persistent file (best-effort)
  pcall(_file_append, line)
end

---------------------------------------------------------------------------
-- guard(ctx, tag, fn, ...)
--   Wraps fn(...) in xpcall with debug.traceback as the error handler.
--   On error: captures the fault and returns (false, traceback).
--   On success: returns (true, result).
--
--   The fn receives NO special arguments beyond what is passed.
---------------------------------------------------------------------------
function FaultNet.guard(ctx, tag, fn, ...)
  -- Capture varargs immediately — cannot use ... inside nested functions.
  local args = {...}
  local arg_count = select("#", ...)
  local unpack = table.unpack or unpack

  local function wrapped()
    if arg_count == 0 then
      return fn()
    else
      return fn(unpack(args, 1, arg_count))
    end
  end

  local ok, result = xpcall(wrapped, function(err)
    -- Build a full traceback anchored at the error
    local tb = debug.traceback(tostring(err), 2)
    return tb
  end)

  if not ok then
    -- result is the traceback string from xpcall
    FaultNet.capture(ctx, tag, result)
    return false, result
  end

  return true, result
end

---------------------------------------------------------------------------
-- Hook a ctx so downstream code can call FaultNet.capture / FaultNet.guard
-- without needing to pass ctx every time (convenience).
-- Returns a table with ctx-bound wrappers.
---------------------------------------------------------------------------
function FaultNet.bind(ctx)
  return {
    capture = function(tag, err, extra)
      return FaultNet.capture(ctx, tag, err, extra)
    end,
    guard = function(tag, fn, ...)
      return FaultNet.guard(ctx, tag, fn, ...)
    end,
  }
end

return FaultNet
