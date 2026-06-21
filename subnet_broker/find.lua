--[[
  AutoOS — find broker scripts, clear cache, run fresh from disk
  build: 2026-06-16b

  loadfile("/home/subnet_broker/find.lua")("probe")
  loadfile("/home/subnet_broker/find.lua")("probe", "machine_01")
  loadfile("/home/subnet_broker/find.lua")("ver")
  loadfile("/home/subnet_broker/find.lua")("run", "diag.lua")

  Output is mirrored to find.txt in the same folder (cat find.txt).
]]

local FIND_BUILD = "2026-06-16b"

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local fs = require("filesystem")

local BROKER_MODULES = {
  "config", "hw", "lane_sides", "lane_dispatch", "central_dispatch", "maintenance_parse",
  "machine_poll", "circuit_manager", "array_watch", "network_protocols",
  "broker_main", "broker_entry", "broker_bootstrap", "broker_registry_adapter",
  "broker_diagnostics", "broker_event_bus", "broker_poll_cache", "broker_test_tick",
  "dispatch_clock", "task_registry",
  "tasks/task_modem_rx", "tasks/task_component_events", "tasks/task_central_input_events",
  "tasks/task_machine_poll", "tasks/task_central_dispatch", "tasks/task_lane_worker",
  "tasks/task_heartbeat",
  "probe_transposer", "diag", "start", "find",
}

local SIDE_NAMES = {
  [0] = "bottom", [1] = "top", [2] = "back",
  [3] = "front", [4] = "right", [5] = "left",
}

local function join(a, b)
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

local log_path = join(here, "find.txt")
local log_file = io.open(log_path, "w")
local _print = print
function print(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, "\t")
  _print(line)
  if log_file then log_file:write(line .. "\n") end
end

local function export_done()
  if log_file then
    log_file:flush()
    log_file:close()
    log_file = nil
    _print("[find] exported to " .. log_path)
  end
end

local function clear_all()
  for _, stem in ipairs(BROKER_MODULES) do
    package.loaded[stem] = nil
  end
end

local function read_head(path, n)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read(n or 2048) or ""
  f:close()
  return s
end

--- Always read bytes from disk — never use cached require/loadfile body.
local function run_fresh(path, ...)
  local f = io.open(path, "r")
  if not f then
    print("[find] cannot open " .. path)
    return false
  end
  local src = f:read("*a")
  f:close()
  local chunk, err = load(src, "@" .. path)
  if not chunk then
    print("[find] load failed: " .. tostring(err))
    return false
  end
  print("[find] running " .. path)
  local ok, run_err = pcall(chunk, ...)
  if not ok then
    print("[find] error:\n" .. tostring(run_err))
    return false
  end
  return true
end

local function list_lua(root, pattern, hits, depth)
  depth = depth or 0
  if depth > 8 then return end
  if not fs.exists(root) then return end
  for _, name in ipairs(fs.list(root)) do
    local path = join(root, name)
    if fs.isDirectory(path) then
      if name ~= "." and name ~= ".." then list_lua(path, pattern, hits, depth + 1) end
    elseif name:match("%.lua$") and (not pattern or name:find(pattern, 1, true)) then
      hits[#hits + 1] = path
    end
  end
end

-- Embedded probe (fallback when probe_transposer.lua on disk is still the old build)
local function run_probe_embedded(only)
  package.loaded.config = nil
  package.loaded.lane_sides = nil
  local Config = require("config")
  local LaneSides = require("lane_sides")
  local component = require("component")

  local function add_hint(hints, side, label)
    if type(side) ~= "number" then return end
    local prev = hints[side]
    hints[side] = prev and (prev .. ", " .. label) or label
  end

  local function mark_for(side, hints)
    local text = hints[side]
    if not text or text == "" then return "" end
    return "  <<" .. text .. ">>"
  end

  local function fluid_mb(tp, side)
    if not tp.getTankLevel then return nil end
    local ok, lvl = pcall(tp.getTankLevel, side, 1)
    if ok and type(lvl) == "number" and lvl > 0 then return lvl end
    return nil
  end

  local function tp_proxy(addr)
    local ok, tp = pcall(component.proxy, addr, "transposer")
    if ok and tp then return tp end
    ok, tp = pcall(component.proxy, addr)
    return ok and tp or nil
  end

  local function probe_one(label, addr, hints)
    print(string.format("  [%s] transposer %s", label, tostring(addr)))
    local tp = tp_proxy(addr)
    if not tp then print("    ERROR: proxy failed"); return end
    for side = 0, 5 do
      local inv_ok, inv_size = pcall(tp.getInventorySize, side)
      inv_size = inv_ok and inv_size or 0
      local fluid = fluid_mb(tp, side)
      local parts = {}
      if inv_size and inv_size > 0 then parts[#parts + 1] = inv_size .. " item slots" end
      if fluid then parts[#parts + 1] = fluid .. " mB fluid" end
      if #parts == 0 then parts[#parts + 1] = "empty" end
      print(string.format("    side %d (%s): %s%s",
        side, SIDE_NAMES[side] or "?", table.concat(parts, ", "), mark_for(side, hints)))
    end
  end

  print("[AutoOS] Dual transposer probe " .. FIND_BUILD .. " (embedded)")
  for _, m in ipairs(Config.machines) do
    if not only or only == "" or m.id == only then
      print(string.rep("-", 56))
      print("[Probe] " .. m.id)
      local ih, fh = {}, {}
      add_hint(ih, m.side_buffer, "side_buffer")
      add_hint(ih, m.side_bus_b, "side_bus_b")
      add_hint(ih, m.side_return or m.side_buffer, "side_return")
      add_hint(fh, LaneSides.fluid_buffer_side(m), "side_fluid_buffer")
      add_hint(fh, LaneSides.fluid_hatch_side(m), "side_fluid_hatch")
      print(string.format("  item  buffer=%s bus=%s return=%s",
        tostring(m.side_buffer), tostring(m.side_bus_b), tostring(m.side_return or m.side_buffer)))
      print(string.format("  fluid buffer=%s hatch=%s",
        tostring(LaneSides.fluid_buffer_side(m)), tostring(LaneSides.fluid_hatch_side(m))))
      probe_one("item", LaneSides.item_transposer_address(m), ih)
      probe_one("fluid", LaneSides.fluid_transposer_address(m), fh)
    end
  end
  print(string.rep("-", 56))
end

local cmd = ...
local arg2 = select(2, ...)
local arg3 = select(3, ...)

local function main()
if not cmd or cmd == "" or cmd == "help" then
  print("[find] " .. FIND_BUILD)
  print("  probe [lane_id]  — transposer face map (embedded, ignores stale file)")
  print("  ver              — show probe_transposer.lua build on disk")
  print("  run <file> [arg] — io.open+load fresh")
  print("  clear            — package.loaded broker modules")
  print("  list             — .lua under " .. here)
  cmd = "list"
end

if cmd == "ver" then
  local path = join(here, "probe_transposer.lua")
  local head = read_head(path, 512) or "(missing)"
  print("[find] probe_transposer.lua on disk:")
  print(head:sub(1, 200))
  if head:find("2026-06-16b", 1, true) then
    print("[find] OK — disk copy is current")
  else
    print("[find] STALE — use find('probe') or wget new probe_transposer.lua")
  end
  return
end

if cmd == "probe" then
  clear_all()
  local path = join(here, "probe_transposer.lua")
  local head = read_head(path, 512) or ""
  if head:find("2026-06-16b", 1, true) then
    run_fresh(path, arg2)
  else
    if head ~= "" then
      print("[find] disk probe is old — using embedded probe")
    end
    run_probe_embedded(arg2)
  end
  return
end

if cmd == "clear" then
  if arg2 and arg2 ~= "" then
    package.loaded[arg2:gsub("%.lua$", "")] = nil
    print("[find] cleared " .. arg2)
  else
    clear_all()
    print("[find] cleared all broker modules")
  end
  return
end

if cmd == "run" then
  if not arg2 or arg2 == "" then
    print("[find] run needs filename")
    return
  end
  local name = arg2:match("%.lua$") and arg2 or (arg2 .. ".lua")
  clear_all()
  local path = join(here, name)
  if fs.exists(path) then
    run_fresh(path, arg3)
    return
  end
  local hits = {}
  list_lua(here, name:gsub("%.lua$", ""), hits)
  if #hits == 0 then print("[find] not found: " .. name); return end
  run_fresh(hits[1], arg3)
  return
end

if cmd == "list" then
  local hits = {}
  list_lua(here, nil, hits)
  table.sort(hits)
  for _, p in ipairs(hits) do print(p) end
  print("[find] " .. #hits .. " files")
  return
end

local hits = {}
list_lua(here, cmd, hits)
for _, p in ipairs(hits) do print(p) end
end

main()
export_done()
