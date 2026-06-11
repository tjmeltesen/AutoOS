--[[
  Universal tests — package.path setup and assertion helpers.
]]

local M = {}

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/test_harness.lua"
local tests_dir = script:match("^(.*)[/\\]") or "."
local universal_root = tests_dir .. sep .. ".."
local project_root = universal_root .. sep .. ".."

package.path = table.concat({
  universal_root .. sep .. "?.lua",
  tests_dir .. sep .. "?.lua",
  project_root .. sep .. "?.lua",
  package.path,
}, ";")

M.universal_root = universal_root
M.project_root = project_root

local ESC = string.char(27)
local function color(code, t) return ESC .. "[" .. code .. "m" .. t .. ESC .. "[0m" end

M.passed = 0
M.failed = 0

function M.check(name, ok, detail)
  if ok then
    M.passed = M.passed + 1
    io.write(color("32", "  PASS  ") .. name)
  else
    M.failed = M.failed + 1
    io.write(color("31", "  FAIL  ") .. name)
  end
  if detail then io.write(color("2", "  -  " .. detail)) end
  io.write("\n")
end

function M.summary(title)
  io.write("\n" .. color("1", title) .. "\n")
  io.write(string.rep("-", 60) .. "\n")
end

function M.report()
  io.write(string.format("\n%s  %d passed, %d failed\n",
    M.failed == 0 and color("32", "OK") or color("31", "FAIL"),
    M.passed, M.failed))
  return M.failed == 0
end

return M
