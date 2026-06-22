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
  -- subnet_broker/ — broker core (destination: /home/subnet_broker/)
  "subnet_broker/config.lua",
  "subnet_broker/registry.lua",
  "subnet_broker/hw.lua",
  "subnet_broker/broker_main.lua",
  "subnet_broker/broker_entry.lua",
  "subnet_broker/broker_bootstrap.lua",
  "subnet_broker/broker_registry_adapter.lua",
  "subnet_broker/broker_diagnostics.lua",
  "subnet_broker/broker_event_bus.lua",
  "subnet_broker/broker_poll_cache.lua",
  "subnet_broker/broker_test_tick.lua",
  "subnet_broker/dispatch_clock.lua",
  "subnet_broker/task_registry.lua",
  "subnet_broker/tasks/task_modem_rx.lua",
  "subnet_broker/tasks/task_component_events.lua",
  "subnet_broker/tasks/task_central_input_events.lua",
  "subnet_broker/tasks/task_machine_poll.lua",
  "subnet_broker/tasks/task_central_dispatch.lua",
  "subnet_broker/tasks/task_lane_worker.lua",
  "subnet_broker/tasks/task_heartbeat.lua",
  "subnet_broker/broker_boot.lua",
  "subnet_broker/rob_dispatcher.lua",
  "subnet_broker/rob_tick.lua",
  "subnet_broker/rob_core/constants.lua",
  "subnet_broker/rob_core/job_manifest.lua",
  "subnet_broker/rob_core/job_descriptor.lua",
  "subnet_broker/rob_core/lane_state.lua",
  "subnet_broker/rob_core/lock_manager.lua",
  "subnet_broker/rob_services/buffer_monitor.lua",
  "subnet_broker/rob_services/admission_control.lua",
  "subnet_broker/rob_services/job_factory.lua",
  "subnet_broker/rob_services/machine_selector.lua",
  "subnet_broker/rob_services/completion_detector.lua",
  "subnet_broker/rob_services/watchdog.lua",
  "subnet_broker/rob_services/job_reaper.lua",
  "subnet_broker/rob_services/job_assigner.lua",
  "subnet_broker/lane_worker.lua",
  "subnet_broker/lane_sides.lua",
  "subnet_broker/machine_poll.lua",
  "subnet_broker/circuit_manager.lua",
  "subnet_broker/coroutine_scheduler.lua",
  "subnet_broker/fluid_tanks.lua",
  "subnet_broker/descriptor_cache.lua",
  "subnet_broker/find.lua",
  "subnet_broker/maintenance_parse.lua",
  "subnet_broker/network_protocols.lua",
  "subnet_broker/fault_net.lua",
  -- subnet_broker/ — broker TUI (single-file, no page deps)
  "subnet_broker/broker_ui.lua",
  "subnet_broker/page_dashboard.lua",
  "subnet_broker/page_logs.lua",
  "subnet_broker/page_config.lua",
  "subnet_broker/ui_utils.lua",
  "subnet_broker/ui_components.lua",
  "subnet_broker/class_base_page.lua",
  -- /home/ — standalone UI scripts (repo: subnet_broker/, dest: /home/)
  { src = "subnet_broker/broker_ui_main.lua", dest = "broker_ui_main.lua" },
  { src = "subnet_broker/broker_config.lua", dest = "broker_config.lua" },
  { src = "subnet_broker/broker_logs.lua", dest = "broker_logs.lua" },
  -- shared/ — cross-cutting protocol definitions
  "shared/network_protocols.lua",

  -- orchestrator/ — central AE orchestration
  --"orchestrator/orchestrator_main.lua",
  --"orchestrator/orchestrator.lua",
  --"orchestrator/orchestrator_config.lua",
  --"orchestrator/hw.lua",
  --"orchestrator/network_protocols.lua",
  --"orchestrator/modem_comm_test.lua",
  --"orchestrator/modem_info.lua",
  --"orchestrator/modem_listen.lua",
  --"orchestrator/modem_ping.lua",
  --"orchestrator/start.lua",

  -- tests/  (run via lua tests/<name>.lua)
  "tests/coroutine_scheduler_test.lua",
  "tests/descriptor_cache_test.lua",
  "tests/fluid_tanks_test.lua",
  "tests/mock_broker_hardware.lua",
  "tests/mock_network.lua",
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

local function download_file(entry)
  -- entry is either a string (repo-relative path → same dest path)
  -- or a table { src = "repo/path", dest = "dest/path" } (different dest)
  local src_path = type(entry) == "table" and entry.src or entry
  local dest_rel = type(entry) == "table" and entry.dest or entry
  local url = BASE .. "/" .. src_path
  local dest = TARGET_ROOT .. "/" .. dest_rel
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

  for i, entry in ipairs(FILES) do
    local src_path = type(entry) == "table" and entry.src or entry
    local dest_rel = type(entry) == "table" and entry.dest or entry
    local status = string.format("[%3d/%3d]", i, total)

    -- Check if BASE has been configured
    if BASE:find("YOUR_USERNAME") then
      print(status .. " SKIP (BASE URL not configured): " .. src_path)
      skipped = skipped + 1
    else
      -- Skip config.lua if it already exists (preserve user config)
      if src_path:find("config%.lua$") then
        local dest = TARGET_ROOT .. "/" .. dest_rel
        local f = io.open(dest, "r")
        if f then f:close(); print(status .. " SKIP (exists): " .. src_path); skipped = skipped + 1; goto continue end
      end
      ensure_dir(dest_rel)
      io.write(status .. " " .. src_path .. " ... ")
      local result = download_file(entry)
      if result == 0 or result == true then
        print("OK")
        ok_count = ok_count + 1
      else
        print("FAIL (code " .. tostring(result) .. ")")
        fail_count = fail_count + 1
      end
      ::continue::
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
