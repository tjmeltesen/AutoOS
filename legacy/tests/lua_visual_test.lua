#!/usr/bin/env lua
--[[
  AutoOS — Lua runtime visual smoke test

  Uses ASCII-only drawing so output looks correct in every Windows terminal
  (cmd, PowerShell, Cursor integrated terminal). Unicode box chars show as
  garbage (e.g. ΓöÇ) when the console code page is not UTF-8.

  Run from project root:
    C:\Lua\lua55.exe tests\lua_visual_test.lua
]]

--------------------------------------------------------------------------------
-- ANSI colors (needs Windows Terminal or VT-enabled console for colors)
--------------------------------------------------------------------------------

local ESC = string.char(27)
local is_windows = package.config:sub(1, 1) == "\\"

local function enable_ansi_windows()
  if not is_windows then return end
  -- Turn on ANSI/VT output in classic consoles (Win10+). Silent if it fails.
  os.execute("reg add HKCU\\Console /v VirtualTerminalLevel /t REG_DWORD /d 1 /f >nul 2>nul")
end

local function c(code, text)
  return ESC .. "[" .. code .. "m" .. text .. ESC .. "[0m"
end

local bold   = function(t) return c("1",  t) end
local green  = function(t) return c("32", t) end
local red    = function(t) return c("31", t) end
local yellow = function(t) return c("33", t) end
local cyan   = function(t) return c("36", t) end
local dim    = function(t) return c("2",  t) end

--------------------------------------------------------------------------------
-- Helpers (ASCII only — no Unicode box drawing)
--------------------------------------------------------------------------------

local function sleep(seconds)
  if is_windows then
    local ms = math.max(1, math.floor(seconds * 1000))
    os.execute(string.format('powershell -NoProfile -Command "Start-Sleep -Milliseconds %d" >nul 2>nul', ms))
  else
    os.execute(string.format("sleep %.2f 2>/dev/null", seconds))
  end
end

local function line(ch, width)
  io.write(string.rep(ch or "-", width or 60) .. "\n")
end

local function platform_label()
  if is_windows then return "Windows" end
  return "Unix/Linux"
end

local passed = 0
local failed = 0

local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    io.write(green("  PASS  ") .. name)
  else
    failed = failed + 1
    io.write(red("  FAIL  ") .. name)
  end
  if detail then io.write(dim("  -  " .. detail)) end
  io.write("\n")
end

--------------------------------------------------------------------------------
-- Banner
--------------------------------------------------------------------------------

enable_ansi_windows()

io.write("\n")
io.write(bold(cyan("  +======================================================+\n")))
io.write(bold(cyan("  |         AutoOS - Lua Visual Runtime Test             |\n")))
io.write(bold(cyan("  +======================================================+\n")))
io.write("\n")

io.write("  Lua version : " .. bold(_VERSION) .. "\n")
io.write("  Platform    : " .. platform_label() .. "\n")
io.write("  Script path : " .. (arg and arg[0] or "lua_visual_test.lua") .. "\n")
io.write("\n")

--------------------------------------------------------------------------------
-- Color palette demo
--------------------------------------------------------------------------------

io.write(bold("Color palette\n"))
line("-", 60)
io.write("  " .. red("red") .. "  " .. green("green") .. "  " .. yellow("yellow") .. "  " .. cyan("cyan") .. "  " .. bold("bold") .. "  " .. dim("dim") .. "\n")
io.write(dim("  (If all words look the same color, open Windows Terminal for ANSI colors.)\n"))
io.write("\n")

--------------------------------------------------------------------------------
-- Animated progress bar
--------------------------------------------------------------------------------

io.write(bold("Animated bar (watch the terminal)\n"))
line("-", 60)

local bar_width = 40
io.write("  [")
for i = 0, bar_width do
  local pct = math.floor((i / bar_width) * 100)
  local filled = string.rep("#", i) .. string.rep(".", bar_width - i)
  io.write("\r  [" .. filled .. "] " .. string.format("%3d%%", pct))
  io.flush()
  sleep(0.03)
end
io.write("\n\n")

--------------------------------------------------------------------------------
-- Language / AutoOS-relevant checks
--------------------------------------------------------------------------------

io.write(bold("Runtime checks\n"))
line("-", 60)

check("math.floor works", math.floor(3.7) == 3)
check("string.format works", string.format("%.1f", 1.5) == "1.5")
check("tables + ipairs", (function()
  local t = {10, 20, 30}
  local sum = 0
  for _, v in ipairs(t) do sum = sum + v end
  return sum == 60
end)())
check("os.clock available", type(os.clock()) == "number", string.format("%.4fs", os.clock()))
check("os.time available", type(os.time()) == "number")
check("pcall error handling", (function()
  local ok, err = pcall(function() error("boom") end)
  return not ok and type(err) == "string"
end)())

local STATE_IDLE, STATE_ACTIVE = "IDLE", "ACTIVE"
local state = STATE_IDLE
local low, high = 100, 200
local function tick(stock)
  if state == STATE_IDLE and stock < low then state = STATE_ACTIVE end
  if state == STATE_ACTIVE and stock > high then state = STATE_IDLE end
  return state
end
check("hysteresis logic", tick(50) == STATE_ACTIVE and tick(250) == STATE_IDLE)

local history = {}
local function push(count, t)
  table.insert(history, {t = t, count = count})
  if #history > 5 then table.remove(history, 1) end
end
push(100, 0); push(90, 1); push(80, 2)
local delta = (history[3].count - history[1].count) / (history[3].t - history[1].t)
check("velocity delta", delta == -10, "dR = " .. tostring(delta))

io.write("\n")

--------------------------------------------------------------------------------
-- Mock component pattern (desktop emulator shape)
--------------------------------------------------------------------------------

io.write(bold("Mock hardware tick (README emulator pattern)\n"))
line("-", 60)

local mock_state = { active = true, stock = 142800 }
local mock_gt = {
  setWorkAllowed = function(v) mock_state.active = v end,
  isWorkAllowed = function() return mock_state.active end,
}
local mock_me = {
  getItemsInNetwork = function()
    return {{ label = "Soldering Alloy", size = mock_state.stock }}
  end,
}

mock_gt.setWorkAllowed(false)
local items = mock_me.getItemsInNetwork()
io.write("  Machine active : " .. tostring(mock_gt.isWorkAllowed()) .. "\n")
io.write("  ME stock       : " .. tostring(items[1].size) .. " L\n")
check("mock adapter tick", not mock_gt.isWorkAllowed() and items[1].size == 142800)

io.write("\n")

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

line("=", 60)
if failed == 0 then
  io.write(bold(green(string.format("  All %d checks passed. Lua is ready for AutoOS desktop work.\n", passed))))
  io.write(dim("  Note: OpenComputers in GTNH uses Lua 5.2 in-game. Desktop tests here\n"))
  io.write(dim("  validate logic; final in-game verification still required.\n"))
else
  io.write(bold(red(string.format("  %d check(s) failed, %d passed.\n", failed, passed))))
end
line("=", 60)
io.write("\n")

os.exit(failed == 0 and 0 or 1)
