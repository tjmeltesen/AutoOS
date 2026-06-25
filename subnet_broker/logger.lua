--[[
  AutoOS — Universal Logger
  Single sink for all file logging. Callable from anywhere without ctx.

  Logger.lane(msg)   -- buffered write to lane_worker.log (flush every line, rotate 150)
  Logger.fault(msg)  -- unbuffered write to fault.log (immediate, rotate 500)
  Logger.flush(ch)   -- force flush buffer ("lane" only; "fault" is always flushed)
]]

local Logger = {}

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local LANE_PATH = "/home/subnet_broker/lane_worker.log"
local FAULT_PATH = "/home/subnet_broker/fault.log"
local LANE_ROTATE_LINES = 500
local FAULT_ROTATE_LINES = 500

---------------------------------------------------------------------------
-- Module-level state (one counter per channel — no split-brain)
---------------------------------------------------------------------------
local _lane_writes = 0
local _lane_buffer = {}
local _fault_writes = 0
local _dir_ensured = false
local _console_echo_count = 0  -- echo first N writes to console for visibility

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------
local function _ensure_dir()
  if _dir_ensured then return end
  _dir_ensured = true
  local ok, fs = pcall(require, "filesystem")
  if ok and type(fs) == "table" and fs.makeDirectory then
    pcall(fs.makeDirectory, "/home/subnet_broker")
  end
end

local function _timestamp()
  local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  if ok and type(s) == "string" then return s end
  return tostring(os.time and os.time() or 0)
end

---------------------------------------------------------------------------
-- Logger.flush(channel)
-- Force flush the lane buffer. Fault channel has no buffer (no-op).
---------------------------------------------------------------------------
function Logger.flush(channel)
  if channel == "lane" then
    if #_lane_buffer == 0 then return end
    _ensure_dir()
    local ok, res = pcall(function()
      local f, err = io.open(LANE_PATH, "a")
      if not f then
        error("open failed: " .. tostring(err or "nil"))
      end
      for _, line in ipairs(_lane_buffer) do
        f:write(line .. "\n")
      end
      f:close()
    end)
    if not ok then
      print("[logger] ERROR flushing lane log: " .. tostring(res or "nil"))
    end
    _lane_buffer = {}
  end
  -- fault has no buffer — nothing to flush
end

---------------------------------------------------------------------------
-- Logger.lane(msg)
-- Buffered lane log. Flushes every line (LOG_BUF_MAX = 1).
-- Rotates (truncates) after LANE_ROTATE_LINES writes.
---------------------------------------------------------------------------
function Logger.lane(msg)
  _ensure_dir()
  _lane_writes = _lane_writes + 1
  if _lane_writes > LANE_ROTATE_LINES then
    _lane_writes = 1
    Logger.flush("lane")  -- drain any remaining buffer
    pcall(function()
      local w = io.open(LANE_PATH, "w")
      if w then w:close() end
    end)
  end
  _lane_buffer[#_lane_buffer + 1] = string.format("[%s] %s", _timestamp(), msg)
  if #_lane_buffer >= 1 then Logger.flush("lane") end
  -- Echo first writes to console so operator can confirm logger is alive
  if _console_echo_count < 5 then
    _console_echo_count = _console_echo_count + 1
    print("[logger] lane #" .. _console_echo_count .. ": " .. msg:sub(1, 120))
  end
end

---------------------------------------------------------------------------
-- Logger.fault(msg)
-- Unbuffered fault log. Writes immediately.
-- Rotates (truncates) after FAULT_ROTATE_LINES writes.
---------------------------------------------------------------------------
function Logger.fault(msg)
  _ensure_dir()
  _fault_writes = _fault_writes + 1
  local mode = "a"
  if _fault_writes > FAULT_ROTATE_LINES then
    _fault_writes = 1
    mode = "w"
  end
  local ok, res = pcall(function()
    local f, err = io.open(FAULT_PATH, mode)
    if not f then
      error("open failed: " .. tostring(err or "nil"))
    end
    f:write(msg .. "\n")
    f:close()
  end)
  if not ok then
    print("[logger] ERROR writing fault log: " .. tostring(res or "nil"))
  end
  -- Echo first writes to console
  if _console_echo_count < 10 then
    _console_echo_count = _console_echo_count + 1
    print("[logger] fault: " .. msg:sub(1, 120))
  end
end

---------------------------------------------------------------------------
-- Startup self-test — proves logger is loaded and paths are writable.
-- Call once from bootstrap after the filesystem is ready.
---------------------------------------------------------------------------
local _self_test_done = false
function Logger.startup_self_test()
  if _self_test_done then return end
  _self_test_done = true
  local ts = _timestamp()
  _ensure_dir()
  local f1, e1 = io.open(LANE_PATH, "a")
  if f1 then
    f1:write(string.format("[%s] Logger online - lane_worker.log writable\n", ts))
    f1:close()
    print("[logger] STARTUP lane_worker.log writable")
  else
    print("[logger] STARTUP lane_worker.log FAILED: " .. tostring(e1 or "nil"))
  end
  local f2, e2 = io.open(FAULT_PATH, "a")
  if f2 then
    f2:write(string.format("[%s] Logger online - fault.log writable\n", ts))
    f2:close()
    print("[logger] STARTUP fault.log writable")
  else
    print("[logger] STARTUP fault.log FAILED: " .. tostring(e2 or "nil"))
  end
end

-- Fire self-test at module load time so the operator sees the result immediately
Logger.startup_self_test()

return Logger
