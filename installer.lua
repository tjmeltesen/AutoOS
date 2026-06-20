--[[
  AutoOS — Module Installer

  Downloads all AutoOS modules from a GitHub repository to the local
  OpenComputers filesystem. Creates required directory structure and
  fetches each file via wget.

  Usage:
    1. Fill in the BASE_URL below with your repository raw URL.
    2. Run in-game or with a Lua interpreter:
         lua installer.lua

  The script creates the following directories under /home/:
    subnet_broker/   — broker modules (dispatch, config, registry, etc.)
    shared/          — shared protocol definitions
    orchestrator/    — orchestrator modules
    tests/           — test files

  All paths are relative to /home/.
]]

-- =========================================================================
-- CONFIGURATION — fill in your repository details
-- =========================================================================

local BASE = "https://raw.githubusercontent.com/tjmeltesen/AutoOS/main"
-- Example: "https://raw.githubusercontent.com/tjmeltesen/AutoOS/main"

local TARGET_ROOT = "/home"

-- =========================================================================
-- FILE MANIFEST (exhaustive — all files from the repo)
-- =========================================================================

local FILES = {
  -- subnet_broker/ — broker core
  "subnet_broker/config.lua",
  "subnet_broker/registry.lua",
  "subnet_broker/hw.lua",
  "subnet_broker/broker_main.lua",
  "subnet_broker/broker_boot.lua",
  "subnet_broker/rob_dispatcher.lua",
  "subnet_broker/lane_worker.lua",
  "subnet_broker/lane_sides.lua",
  "subnet_broker/lane_dispatch.lua",
  "subnet_broker/machine_poll.lua",
  "subnet_broker/circuit_manager.lua",
  "subnet_broker/coroutine_scheduler.lua",
  "subnet_broker/central_dispatch.lua",
  "subnet_broker/array_watch.lua",
  "subnet_broker/interface_stock.lua",
  "subnet_broker/pull_through.lua",
  "subnet_broker/fluid_tanks.lua",
  "subnet_broker/descriptor_cache.lua",
  "subnet_broker/find.lua",
  "subnet_broker/diag.lua",
  "subnet_broker/probe_transposer.lua",
  "subnet_broker/probe_fluid.lua",
  "subnet_broker/modem_comm_test.lua",
  "subnet_broker/modem_info.lua",
  "subnet_broker/modem_listen.lua",
  "subnet_broker/modem_ping.lua",
  "subnet_broker/maintenance_parse.lua",
  "subnet_broker/network_protocols.lua",
  "subnet_broker/start.lua",
  "subnet_broker/test_recover_transfer.lua",
  -- subnet_broker/ — broker TUI
  "subnet_broker/broker_ui.lua",
  "subnet_broker/broker_ui_main.lua",
  "subnet_broker/broker_ui_dashboard.lua",
  "subnet_broker/broker_ui_logs.lua",
  "subnet_broker/broker_ui_config.lua",

  -- shared/ — cross-cutting protocol definitions
  "shared/network_protocols.lua",

  -- orchestrator/ — central AE orchestration
  "orchestrator/orchestrator_main.lua",
  "orchestrator/orchestrator.lua",
  "orchestrator/orchestrator_config.lua",
  "orchestrator/hw.lua",
  "orchestrator/network_protocols.lua",
  "orchestrator/modem_comm_test.lua",
  "orchestrator/modem_info.lua",
  "orchestrator/modem_listen.lua",
  "orchestrator/modem_ping.lua",
  "orchestrator/start.lua",

  -- tests/
  "tests/broker_ui_test.lua",
}

-- =========================================================================
-- INSTALLATION LOGIC
-- =========================================================================

local function dirname(path)
  return path:match("^(.*)/") or "."
end

local created_dirs = {}

local function ensure_dir(path)
  local dir = dirname(path)
  if dir == "." or created_dirs[dir] then return end
  os.execute("mkdir -p " .. TARGET_ROOT .. "/" .. dir)
  created_dirs[dir] = true
end

local function download_file(rel_path)
  local url = BASE .. "/" .. rel_path
  local dest = TARGET_ROOT .. "/" .. rel_path
  return os.execute("wget -f " .. url .. " " .. dest .. " -q")
end

local function main()
  print("AutoOS Installer")
  print("BASE: " .. BASE)
  print("Target: " .. TARGET_ROOT)
  print(string.rep("-", 50))

  local total = #FILES
  local ok_count = 0
  local fail_count = 0
  local skipped = 0

  for i, rel_path in ipairs(FILES) do
    local status = string.format("[%3d/%3d]", i, total)

    -- Check if BASE has been configured
    if BASE:find("YOUR_USERNAME") then
      print(status .. " SKIP (BASE URL not configured): " .. rel_path)
      skipped = skipped + 1
    else
      ensure_dir(rel_path)
      io.write(status .. " " .. rel_path .. " ... ")
      local result = download_file(rel_path)
      if result == 0 or result == true then
        print("OK")
        ok_count = ok_count + 1
      else
        print("FAIL (code " .. tostring(result) .. ")")
        fail_count = fail_count + 1
      end
    end
  end

  print(string.rep("-", 50))
  print(string.format("Done: %d ok, %d failed, %d skipped",
    ok_count, fail_count, skipped))

  if BASE:find("YOUR_USERNAME") then
    print()
    print("*** Edit installer.lua and set BASE to your repository URL. ***")
    print("    Example: https://raw.githubusercontent.com/tjmeltesen/AutoOS/main")
    return false
  end

  return fail_count == 0
end

local ok, err = pcall(main)
if not ok then
  print("[installer] FATAL: " .. tostring(err))
  os.exit(1)
end
