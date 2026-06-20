--[[
  AutoOS Broker UI — Config Editor Page
  Lua 5.2 / OpenComputers

  Returns: { name = "Config", render = function(gpu, w, h, data), handle_key = function(code, data),
             build_data = function(config_path), save_config = function(data, config_path) }
]]

local module = { name = "Config" }

-------------------------------------------------------------------------------
-- Box-drawing helpers
-------------------------------------------------------------------------------
local BOX_H = "\226\148\128"   -- ─
local BOX_VD = "\226\148\156"  -- ├
local BOX_VDB = "\226\148\164" -- ┤

-------------------------------------------------------------------------------
-- Colour constants
-------------------------------------------------------------------------------
local C_BLACK   = 0x000000
local C_WHITE   = 0xFFFFFF
local C_GRAY    = 0x808080
local C_DKGRAY  = 0x404040
local C_RED     = 0xFF0000
local C_GREEN   = 0x00FF00
local C_CYAN    = 0x00FFFF
local C_YELLOW  = 0xFFFF00

-------------------------------------------------------------------------------
-- Serialization helpers
-------------------------------------------------------------------------------
local function serialize_value(v)
  if v == nil then
    return "nil"
  elseif type(v) == "boolean" then
    return v and "true" or "false"
  elseif type(v) == "number" then
    return tostring(v)
  elseif type(v) == "string" then
    return string.format("%q", v)
  else
    return tostring(v)
  end
end

local function indent(level)
  return string.rep("  ", level)
end

--[[
  Build a flat table from the sections/fields data structure.
  Returns a table mirroring Config structure: top-level keys, scheduler sub-table,
  central sub-table, machines array.
]]
local function build_config_table(data)
  local cfg = {}
  cfg.scheduler = {}
  cfg.central = {}
  cfg.machines = {}

  for _, sec in ipairs(data.sections) do
    if sec.key and sec.key == "machines" then
      -- machines are stored in data.machines, already in the correct format
      if data.machines then
        for i, m in ipairs(data.machines) do
          cfg.machines[i] = {}
          for k, v in pairs(m) do
            cfg.machines[i][k] = v
          end
        end
      end
    elseif sec.table_key then
      -- sub-table section (scheduler, central)
      local sub = {}
      for _, f in ipairs(sec.fields) do
        sub[f.key] = f.value
      end
      cfg[sec.table_key] = sub
    else
      -- top-level fields
      for _, f in ipairs(sec.fields) do
        cfg[f.key] = f.value
      end
    end
  end

  return cfg
end

--[[
  Serialize a complete Config table back to a Lua source string
  that matches the structure of config.lua.
]]
local function serialize_config(cfg)
  local lines = {}
  lines[#lines + 1] = "--[["
  lines[#lines + 1] = "  AutoOS — Subnet Broker Config (LCR dual transposer)"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  input_mode:"
  lines[#lines + 1] = "    per_lane — AE deposits to each lane buffer (LCR reference)"
  lines[#lines + 1] = "    central  — AE deposits to shared chest via storage bus; adapter monitor + stabilize_s"
  lines[#lines + 1] = "]]"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "local Config = {}"
  lines[#lines + 1] = ""

  -- Top-level simple fields (in order matching original config.lua)
  local top_order = {
    "subnet_id", "main_net_channel", "input_mode", "completion_mode",
    "do_round_robin", "circuit_item_name",
    "database_address", "database_slot_count",
    "interface_item_slots", "interface_item_slot_start",
    "interface_fluid_side", "shared_interface_address",
    "chest_slot_start", "circuit_bus_slot",
    "settle_s", "tick_interval", "monitor_poll_s",
    "staging_timeout_s", "completion_timeout_s", "require_empty_return",
    "orchestrator_address", "broker_modem_port",
    "redstone_address", "redstone_side", "redstone_pulse_s",
  }

  -- Collect top-level values
  local top = {}
  for _, key in ipairs(top_order) do
    if cfg[key] ~= nil then
      top[key] = cfg[key]
    end
  end
  -- Also include any top-level keys not in the canonical order
  for k, v in pairs(cfg) do
    if type(v) ~= "table" and top[k] == nil then
      top[k] = v
    end
  end

  for _, key in ipairs(top_order) do
    local v = top[key]
    if v ~= nil then
      lines[#lines + 1] = "Config." .. key .. " = " .. serialize_value(v)
    end
  end

  -- Scheduler sub-table
  local sched = cfg.scheduler or {}
  lines[#lines + 1] = "Config.scheduler = {"
  local sched_order = { "max_parallel_lanes", "max_job_attempts", "watchdog_grace_s", "persist_jobs", "active_lane_budget" }
  for _, key in ipairs(sched_order) do
    local v = sched[key]
    if v ~= nil then
      lines[#lines + 1] = "  " .. key .. " = " .. serialize_value(v) .. ","
    end
  end
  lines[#lines + 1] = "}"

  lines[#lines + 1] = ""

  -- Central sub-table
  local central = cfg.central or {}
  lines[#lines + 1] = "Config.central = {"
  local central_order = {
    "monitor", "inventory_controller_side",
    "buffer_adapter_address", "buffer_adapter_side",
    "fluid_adapter_address", "fluid_adapter_side",
    "chest_slot_start", "max_circuits_in_buffer",
    "ingest_mode", "job_stabilize_s", "stabilize_s", "settle_s",
    "interface_wait_s", "require_interface_staging",
  }
  for _, key in ipairs(central_order) do
    local v = central[key]
    if v ~= nil then
      lines[#lines + 1] = "  " .. key .. " = " .. serialize_value(v) .. ","
    end
  end
  lines[#lines + 1] = "}"

  lines[#lines + 1] = ""

  -- Machines array
  local machines = cfg.machines or {}
  lines[#lines + 1] = "Config.machines = {"
  for i, m in ipairs(machines) do
    lines[#lines + 1] = "  {"
    local machine_order = {
      "id", "gt_address", "interface_address",
      "item_transposer_address", "fluid_transposer_address",
      "side_buffer", "side_bus_b", "side_return",
      "side_fluid_buffer", "side_fluid_hatch",
      "input_slot",
    }
    for _, key in ipairs(machine_order) do
      local v = m[key]
      if v ~= nil then
        lines[#lines + 1] = "    " .. key .. " = " .. serialize_value(v) .. ","
      end
    end
    -- Include any extra keys
    for k, v in pairs(m) do
      local known = false
      for _, mk in ipairs(machine_order) do
        if k == mk then known = true; break end
      end
      if not known then
        lines[#lines + 1] = "    " .. k .. " = " .. serialize_value(v) .. ","
      end
    end
    lines[#lines + 1] = "  },"
  end
  lines[#lines + 1] = "}"

  lines[#lines + 1] = ""
  lines[#lines + 1] = "return Config"
  lines[#lines + 1] = ""

  return table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- Load and parse the actual config.lua
-------------------------------------------------------------------------------
local function load_config_file(config_path)
  local ok, cfg = pcall(dofile, config_path)
  if not ok or type(cfg) ~= "table" then
    return nil
  end
  return cfg
end

--[[
  Build the sections/fields data structure from a loaded config table.
  Returns the data table ready for the render/handle_key functions.
]]
function module.build_data(config_path)
  local cfg = load_config_file(config_path)

  local data = {
    sections = {},
    focus_section = 1,
    focus_field = 1,
    editing = false,
    edit_buffer = "",
    status_msg = nil,
    config_path = config_path,
    -- Machine sub-editing state
    editing_machine = nil,      -- nil or 1-based machine index
    machine_focus_field = 1,
    -- For saving
    machines = nil,             -- deep copy of machines array for editing
    -- Validation results cache
    _cfg_ref = cfg,             -- reference to loaded config for validation
  }

  -- Deep copy machines array
  if cfg and cfg.machines then
    data.machines = {}
    for i, m in ipairs(cfg.machines) do
      data.machines[i] = {}
      for k, v in pairs(m) do
        data.machines[i][k] = v
      end
    end
  end

  ---------------------------------------------------------------------------
  -- Section 1: Network
  ---------------------------------------------------------------------------
  data.sections[1] = {
    name = "Network",
    fields = {
      { label = "Subnet ID",       key = "subnet_id",              value = (cfg and cfg.subnet_id) or "",               type = "string" },
      { label = "Modem Port",       key = "broker_modem_port",      value = (cfg and cfg.broker_modem_port) or 106,        type = "number", min = 1, max = 65535 },
      { label = "Main Channel",     key = "main_net_channel",       value = (cfg and cfg.main_net_channel) or 105,         type = "number", min = 1, max = 65535 },
      { label = "Orchestrator Addr",key = "orchestrator_address",   value = (cfg and cfg.orchestrator_address) or "",       type = "string" },
    },
  }

  ---------------------------------------------------------------------------
  -- Section 2: Mode & Timing
  ---------------------------------------------------------------------------
  data.sections[2] = {
    name = "Mode & Timing",
    fields = {
      { label = "Input Mode",          key = "input_mode",          value = (cfg and cfg.input_mode) or "central",                type = "enum", choices = { "per_lane", "central" } },
      { label = "Completion Mode",      key = "completion_mode",     value = (cfg and cfg.completion_mode) or "both",               type = "enum", choices = { "both", "adapter", "drain" } },
      { label = "Round Robin",          key = "do_round_robin",      value = (cfg and cfg.do_round_robin) ~= false,                 type = "boolean" },
      { label = "Tick Interval (s)",    key = "tick_interval",       value = (cfg and cfg.tick_interval) or 1.0,                    type = "number", min = 0.01 },
      { label = "Settle (s)",           key = "settle_s",             value = (cfg and cfg.settle_s) or 0.1,                         type = "number", min = 0 },
      { label = "Monitor Poll (s)",     key = "monitor_poll_s",       value = (cfg and cfg.monitor_poll_s) or 0.15,                  type = "number", min = 0.01 },
      { label = "Staging Timeout (s)",  key = "staging_timeout_s",    value = (cfg and cfg.staging_timeout_s) or 60.0,               type = "number", min = 0 },
      { label = "Completion Timeout (s)",key = "completion_timeout_s",value = (cfg and cfg.completion_timeout_s) or 300.0,            type = "number", min = 0 },
      { label = "Require Empty Return", key = "require_empty_return", value = (cfg and cfg.require_empty_return) ~= false,          type = "boolean" },
    },
  }

  ---------------------------------------------------------------------------
  -- Section 3: AE2 & Database
  ---------------------------------------------------------------------------
  data.sections[3] = {
    name = "AE2 & Database",
    fields = {
      { label = "Database Address",       key = "database_address",         value = (cfg and cfg.database_address) or "",                type = "string" },
      { label = "DB Slot Count",          key = "database_slot_count",      value = (cfg and cfg.database_slot_count) or 9,              type = "number", min = 1 },
      { label = "Interface Item Slots",   key = "interface_item_slots",     value = (cfg and cfg.interface_item_slots) or 9,             type = "number", min = 1 },
      { label = "Interface Slot Start",   key = "interface_item_slot_start",value = (cfg and cfg.interface_item_slot_start) or 1,          type = "number", min = 1 },
      { label = "Interface Fluid Side",   key = "interface_fluid_side",      value = (cfg and cfg.interface_fluid_side) or 0,              type = "number", min = 0, max = 5 },
      { label = "Shared IF Address",      key = "shared_interface_address", value = (cfg and cfg.shared_interface_address) or "",         type = "string" },
      { label = "Chest Slot Start",       key = "chest_slot_start",         value = (cfg and cfg.chest_slot_start) or 1,                 type = "number", min = 1 },
      { label = "Circuit Bus Slot",       key = "circuit_bus_slot",          value = (cfg and cfg.circuit_bus_slot) or 1,                  type = "number", min = 1 },
      { label = "Circuit Item Name",      key = "circuit_item_name",        value = (cfg and cfg.circuit_item_name) or "gregtech:gt.integrated_circuit", type = "string" },
    },
  }

  ---------------------------------------------------------------------------
  -- Section 4: Redstone
  ---------------------------------------------------------------------------
  data.sections[4] = {
    name = "Redstone Lock",
    fields = {
      { label = "Redstone Address",  key = "redstone_address",  value = (cfg and cfg.redstone_address) or "",           type = "string" },
      { label = "Redstone Side",    key = "redstone_side",     value = (cfg and cfg.redstone_side) or 0,              type = "number", min = 0, max = 5 },
      { label = "Pulse Duration (s)",key = "redstone_pulse_s",  value = (cfg and cfg.redstone_pulse_s) or 0.5,          type = "number", min = 0 },
    },
  }

  ---------------------------------------------------------------------------
  -- Section 5: Scheduler
  ---------------------------------------------------------------------------
  data.sections[5] = {
    name = "Scheduler",
    table_key = "scheduler",  -- writes to Config.scheduler
    fields = {
      { label = "Max Parallel Lanes", key = "max_parallel_lanes", value = (cfg and cfg.scheduler and cfg.scheduler.max_parallel_lanes) or nil, type = "number", min = 1, nullable = true },
      { label = "Max Job Attempts",   key = "max_job_attempts",    value = (cfg and cfg.scheduler and cfg.scheduler.max_job_attempts) or 2,    type = "number", min = 1 },
      { label = "Watchdog Grace (s)", key = "watchdog_grace_s",    value = (cfg and cfg.scheduler and cfg.scheduler.watchdog_grace_s) or 10,  type = "number", min = 0 },
      { label = "Persist Jobs",       key = "persist_jobs",        value = (cfg and cfg.scheduler and cfg.scheduler.persist_jobs) or "startup_sweep", type = "enum", choices = { "startup_sweep", "file" } },
      { label = "Active Lane Budget", key = "active_lane_budget",  value = (cfg and cfg.scheduler and cfg.scheduler.active_lane_budget) or 32, type = "number", min = 1 },
    },
  }

  ---------------------------------------------------------------------------
  -- Section 6: Central Buffer
  ---------------------------------------------------------------------------
  data.sections[6] = {
    name = "Central Buffer",
    table_key = "central",
    fields = {
      { label = "Monitor Mode",              key = "monitor",                     value = (cfg and cfg.central and cfg.central.monitor) or "inventory_controller", type = "enum", choices = { "inventory_controller", "adapter" } },
      { label = "IC Side",                  key = "inventory_controller_side",   value = (cfg and cfg.central and cfg.central.inventory_controller_side) or 0,     type = "number", min = 0, max = 5 },
      { label = "Buffer Adapter Addr",      key = "buffer_adapter_address",      value = (cfg and cfg.central and cfg.central.buffer_adapter_address) or "",       type = "string" },
      { label = "Buffer Adapter Side",      key = "buffer_adapter_side",          value = (cfg and cfg.central and cfg.central.buffer_adapter_side) or 0,           type = "number", min = 0, max = 5 },
      { label = "Fluid Adapter Addr",       key = "fluid_adapter_address",       value = (cfg and cfg.central and cfg.central.fluid_adapter_address) or "",        type = "string" },
      { label = "Fluid Adapter Side",       key = "fluid_adapter_side",           value = (cfg and cfg.central and cfg.central.fluid_adapter_side) or 0,            type = "number", min = 0, max = 5 },
      { label = "Chest Slot Start",          key = "chest_slot_start",             value = (cfg and cfg.central and cfg.central.chest_slot_start) or 1,              type = "number", min = 1 },
      { label = "Max Circuits In Buffer",    key = "max_circuits_in_buffer",       value = (cfg and cfg.central and cfg.central.max_circuits_in_buffer) or 1,        type = "number", min = 1 },
      { label = "Ingest Mode",              key = "ingest_mode",                  value = (cfg and cfg.central and cfg.central.ingest_mode) or "event_or_poll",     type = "enum", choices = { "event_or_poll", "event", "poll" } },
      { label = "Job Stabilize (s)",        key = "job_stabilize_s",              value = (cfg and cfg.central and cfg.central.job_stabilize_s) or 1.0,            type = "number", min = 0 },
      { label = "Stabilize (s)",            key = "stabilize_s",                   value = (cfg and cfg.central and cfg.central.stabilize_s) or 1.0,                type = "number", min = 0 },
      { label = "Settle (s)",               key = "settle_s",                      value = (cfg and cfg.central and cfg.central.settle_s) or 0.0,                   type = "number", min = 0 },
      { label = "Interface Wait (s)",       key = "interface_wait_s",             value = (cfg and cfg.central and cfg.central.interface_wait_s) or 5.0,           type = "number", min = 0 },
      { label = "Require IF Staging",       key = "require_interface_staging",    value = (cfg and cfg.central and cfg.central.require_interface_staging) or false, type = "boolean" },
    },
  }

  ---------------------------------------------------------------------------
  -- Section 7: Machines
  ---------------------------------------------------------------------------
  data.sections[7] = {
    name = "Machines",
    key = "machines",  -- special marker
  }

  -- Build machine field metadata
  local machine_fields = {
    { label = "ID",                    key = "id",                      type = "string" },
    { label = "GT Address",           key = "gt_address",              type = "string" },
    { label = "Interface Address",    key = "interface_address",       type = "string" },
    { label = "Item TP Address",      key = "item_transposer_address", type = "string" },
    { label = "Fluid TP Address",     key = "fluid_transposer_address",type = "string" },
    { label = "Side Buffer",          key = "side_buffer",             type = "number", min = 0, max = 5 },
    { label = "Side Bus B",           key = "side_bus_b",              type = "number", min = 0, max = 5 },
    { label = "Side Return",          key = "side_return",             type = "number", min = 0, max = 5 },
    { label = "Side Fluid Buffer",    key = "side_fluid_buffer",       type = "number", min = 0, max = 5 },
    { label = "Side Fluid Hatch",     key = "side_fluid_hatch",        type = "number", min = 0, max = 5 },
    { label = "Input Slot",           key = "input_slot",              type = "number", min = 1 },
  }
  data._machine_fields = machine_fields

  return data
end

-------------------------------------------------------------------------------
-- Save config to file
-------------------------------------------------------------------------------
function module.save_config(data, config_path)
  config_path = config_path or data.config_path or "/etc/autoos/config.lua"
  local cfg = build_config_table(data)

  -- Simple validation before saving
  if not cfg.machines or #cfg.machines == 0 then
    data.status_msg = "Error: machines must be non-empty"
    return false
  end
  if not cfg.subnet_id or cfg.subnet_id == "" then
    data.status_msg = "Error: subnet_id is required"
    return false
  end

  local content = serialize_config(cfg)
  local f, err = io.open(config_path, "w")
  if not f then
    data.status_msg = "Error writing config: " .. tostring(err)
    return false
  end
  f:write(content)
  f:close()

  data.status_msg = "Saved OK — " .. config_path
  return true
end

-------------------------------------------------------------------------------
-- Helper: get the currently focused field metadata (respects machine sub-mode)
-------------------------------------------------------------------------------
local function get_current_field(data)
  local sec = data.sections[data.focus_section]
  if not sec then return nil end

  if sec.key == "machines" then
    if data.editing_machine and data.machines and data.machines[data.editing_machine] then
      local mfields = data._machine_fields or {}
      return mfields[data.machine_focus_field]
    else
      -- In machine list view, no "field" to edit directly
      return nil
    end
  else
    return sec.fields[data.focus_field]
  end
end

--[[
  Get the current value of the focused field.
  For machine fields, reads from data.machines[editing_machine].
]]
local function get_current_value(data)
  local sec = data.sections[data.focus_section]
  if not sec then return nil end

  if sec.key == "machines" and data.editing_machine and data.machines and data.machines[data.editing_machine] then
    local mfields = data._machine_fields or {}
    local mf = mfields[data.machine_focus_field]
    if mf then
      return data.machines[data.editing_machine][mf.key]
    end
    return nil
  else
    local f = sec.fields[data.focus_field]
    if f then return f.value end
    return nil
  end
end

--[[
  Set the current value of the focused field.
]]
local function set_current_value(data, val)
  local sec = data.sections[data.focus_section]
  if not sec then return end

  if sec.key == "machines" and data.editing_machine and data.machines and data.machines[data.editing_machine] then
    local mfields = data._machine_fields or {}
    local mf = mfields[data.machine_focus_field]
    if mf then
      data.machines[data.editing_machine][mf.key] = val
    end
  else
    local f = sec.fields[data.focus_field]
    if f then f.value = val end
  end
end

-------------------------------------------------------------------------------
-- Validation helper (mirrors key rules from Config.validate)
-------------------------------------------------------------------------------
local function validate_field(field, new_value)
  if field.type == "number" then
    local n = tonumber(new_value)
    if n == nil then
      return false, "Expected a number"
    end
    if field.min ~= nil and n < field.min then
      return false, "Min: " .. tostring(field.min)
    end
    if field.max ~= nil and n > field.max then
      return false, "Max: " .. tostring(field.max)
    end
    return true, n
  elseif field.type == "enum" then
    if field.choices then
      for _, c in ipairs(field.choices) do
        if c == new_value then
          return true, new_value
        end
      end
      return false, "Must be: " .. table.concat(field.choices, ", ")
    end
    return true, new_value
  elseif field.type == "boolean" then
    -- booleans are toggled, not typed
    return true, new_value
  else
    -- string
    return true, new_value
  end
end

-------------------------------------------------------------------------------
-- Render
-------------------------------------------------------------------------------
function module.render(gpu, w, h, data)
  -- Store dimensions for handle_key
  data._h = h
  data._w = w

  -- Clear
  gpu.setBackground(C_BLACK)
  gpu.fill(1, 1, w, h, " ")

  -----------------------------------------------------------------------
  -- Row 1: Header
  -----------------------------------------------------------------------
  local header = BOX_VD .. " Config " .. BOX_H .. BOX_H .. " "
    .. (data.config_path or "config.lua") .. " "
    .. BOX_H .. BOX_H .. " [Ctrl+S:Save] [Esc:Back] "
  -- Pad to width
  local header_w = #header
  if header_w < w then
    header = header .. string.rep(BOX_H, w - header_w - 1) .. BOX_VDB
  elseif header_w > w then
    header = string.sub(header, 1, w)
  end
  gpu.setForeground(C_GRAY)
  gpu.set(1, 1, header)

  -----------------------------------------------------------------------
  -- Layout calculations
  -----------------------------------------------------------------------
  local left_w = math.floor(w * 0.4)
  if left_w < 8 then left_w = 8 end
  local right_x = left_w + 2
  local right_w = w - left_w - 1
  if right_w < 10 then right_w = 10 end

  local content_h = h - 3  -- rows available for content (row 2 to h-2)

  -----------------------------------------------------------------------
  -- Left pane: Section list
  -----------------------------------------------------------------------
  local row = 2
  for i, sec in ipairs(data.sections) do
    if row > h - 2 then break end
    if i == data.focus_section then
      gpu.setForeground(C_WHITE)
      gpu.setBackground(C_DKGRAY)
      -- Highlight bar
      local bar = " " .. i .. ". " .. sec.name
      if #bar < left_w then
        bar = bar .. string.rep(" ", left_w - #bar)
      else
        bar = string.sub(bar, 1, left_w)
      end
      gpu.set(1, row, bar)
      gpu.setBackground(C_BLACK)
    else
      gpu.setForeground(C_GRAY)
      local label = " " .. i .. ". " .. sec.name
      if #label > left_w then label = string.sub(label, 1, left_w) end
      gpu.set(1, row, label)
    end
    row = row + 1
  end

  -----------------------------------------------------------------------
  -- Right pane: Fields for focused section
  -----------------------------------------------------------------------
  local sec = data.sections[data.focus_section]
  if sec then
    -- Handle machines section specially
    if sec.key == "machines" and not data.editing_machine then
      module._render_machine_list(gpu, right_x, row - 1, right_w, content_h, data)
    elseif sec.key == "machines" and data.editing_machine then
      module._render_machine_fields(gpu, right_x, 2, right_w, content_h, data)
    else
      module._render_fields(gpu, right_x, 2, right_w, content_h, sec.fields, data)
    end
  end

  -----------------------------------------------------------------------
  -- Status message (row h-1)
  -----------------------------------------------------------------------
  if data.status_msg then
    if string.sub(data.status_msg, 1, 5) == "Error" or string.sub(data.status_msg, 1, 5) == "Valid" then
      gpu.setForeground(C_RED)
    else
      gpu.setForeground(C_GREEN)
    end
    local msg = data.status_msg
    if #msg > w then msg = string.sub(msg, 1, w) end
    gpu.set(1, h - 1, msg)
  end

  -----------------------------------------------------------------------
  -- Help bar (row h)
  -----------------------------------------------------------------------
  gpu.setForeground(C_DKGRAY)
  local help = "Tab/S-Tab:move  Enter:edit  Up/Dn:nav  1-7:jump  Ctrl+S:save  Esc:back"
  if data.editing then
    help = "EDIT: Enter:commit  Esc:cancel  Backspace:delete"
  elseif data.editing_machine then
    help = "MACHINE: Enter:edit  Esc:back to list  Up/Dn:nav field"
  end
  if #help > w then help = string.sub(help, 1, w) end
  gpu.set(1, h, help)
end

-- Render a list of fields (for non-machine sections)
function module._render_fields(gpu, x, start_row, rw, max_rows, fields, data)
  if not fields then return end
  local row = start_row
  local focus = data.focus_field
  local sec = data.sections[data.focus_section]

  for i, f in ipairs(fields) do
    if row > start_row + max_rows - 1 then break end

    local is_focused = (i == focus) and not data.editing
    local is_editing_this = (i == focus) and data.editing

    -- Build display line: "label: value"
    local display_val
    if is_editing_this then
      display_val = data.edit_buffer .. "_"  -- cursor
    else
      if f.value == nil then
        display_val = "nil"
      elseif f.type == "boolean" then
        display_val = f.value and "true" or "false"
      else
        display_val = tostring(f.value)
      end
    end

    local label_part = f.label
    local max_label = math.floor(rw * 0.45)
    if #label_part > max_label then
      label_part = string.sub(label_part, 1, max_label - 1) .. "."
    end

    local line = label_part .. ": " .. display_val
    if #line > rw then line = string.sub(line, 1, rw) end

    if is_focused or is_editing_this then
      gpu.setForeground(C_CYAN)
      -- Pad to fill highlight area
      if #line < rw then
        line = line .. string.rep(" ", rw - #line)
      end
    else
      gpu.setForeground(C_WHITE)
    end

    gpu.set(x, row, line)
    row = row + 1
  end
end

-- Render machine list (when in Machines section, not editing a specific machine)
function module._render_machine_list(gpu, x, start_row, rw, max_rows, data)
  local machines = data.machines or {}
  local row = start_row
  local focus = data.focus_field  -- which machine index is highlighted

  if #machines == 0 then
    gpu.setForeground(C_GRAY)
    gpu.set(x, row, "(no machines configured)")
    return
  end

  for i, m in ipairs(machines) do
    if row > start_row + max_rows - 1 then break end

    local mid = m.id or ("machine_" .. i)
    local short_addr = m.gt_address or "?"
    if #short_addr > 12 then
      short_addr = string.sub(short_addr, 1, 12)
    end

    local line = string.format("%d. %s  [%s]", i, mid, short_addr)
    if #line > rw then line = string.sub(line, 1, rw) end

    if i == focus then
      gpu.setForeground(C_CYAN)
      if #line < rw then line = line .. string.rep(" ", rw - #line) end
    else
      gpu.setForeground(C_WHITE)
    end

    gpu.set(x, row, line)
    row = row + 1
  end
end

-- Render a specific machine's fields (sub-edit mode)
function module._render_machine_fields(gpu, x, start_row, rw, max_rows, data)
  local mfields = data._machine_fields or {}
  local mi = data.editing_machine
  local m = data.machines and data.machines[mi]
  if not m then
    gpu.setForeground(C_RED)
    gpu.set(x, start_row, "(machine not found)")
    return
  end

  -- Machine header
  gpu.setForeground(C_YELLOW)
  local mhdr = "Machine " .. mi .. ": " .. (m.id or "?")
  if #mhdr > rw then mhdr = string.sub(mhdr, 1, rw) end
  gpu.set(x, start_row, mhdr)
  start_row = start_row + 1

  local row = start_row
  local focus = data.machine_focus_field

  for i, f in ipairs(mfields) do
    if row > start_row + max_rows - 2 then break end

    local val = m[f.key]
    local display_val
    if data.editing and i == focus then
      display_val = data.edit_buffer .. "_"
    elseif val == nil then
      display_val = "nil"
    elseif val == "" then
      display_val = '""'
    else
      display_val = tostring(val)
    end

    local label_part = f.label
    local max_label = math.floor(rw * 0.45)
    if #label_part > max_label then
      label_part = string.sub(label_part, 1, max_label - 1) .. "."
    end

    local line = label_part .. ": " .. display_val
    if #line > rw then line = string.sub(line, 1, rw) end

    if i == focus then
      gpu.setForeground(C_CYAN)
      if #line < rw then line = line .. string.rep(" ", rw - #line) end
    else
      gpu.setForeground(C_WHITE)
    end

    gpu.set(x, row, line)
    row = row + 1
  end
end

-------------------------------------------------------------------------------
-- Handle Key Input
-------------------------------------------------------------------------------
function module.handle_key(code, data)
  local sec = data.sections[data.focus_section]

  -----------------------------------------------------------------------
  -- Ctrl+S: Save (code 31)
  -----------------------------------------------------------------------
  if code == 31 then
    if data.editing then
      -- Commit current edit first
      module._commit_edit(data)
    end
    module.save_config(data)
    return
  end

  -----------------------------------------------------------------------
  -- Escape: always cancel / go back
  -----------------------------------------------------------------------
  if code == 1 then
    if data.editing then
      data.editing = false
      data.edit_buffer = ""
      data.status_msg = nil
      return
    end
    if data.editing_machine then
      data.editing_machine = nil
      data.status_msg = nil
      return
    end
    -- Otherwise, caller handles Esc to go back to page list
    return
  end

  -----------------------------------------------------------------------
  -- NOT editing: navigation mode
  -----------------------------------------------------------------------
  if not data.editing then

    -- Navigate within machines section
    if sec and sec.key == "machines" then

      if data.editing_machine then
        -- Editing a specific machine's fields
        local mfields = data._machine_fields or {}
        local max_f = #mfields

        if code == 200 then  -- Up
          data.machine_focus_field = math.max(1, data.machine_focus_field - 1)
        elseif code == 208 then  -- Down
          data.machine_focus_field = math.min(max_f, data.machine_focus_field + 1)
        elseif code == 28 then  -- Enter: start editing field
          local mf = mfields[data.machine_focus_field]
          if mf then
            local v = data.machines[data.editing_machine][mf.key]
            if mf.type == "boolean" then
              -- Toggle boolean
              data.machines[data.editing_machine][mf.key] = not v
            elseif mf.type == "enum" and mf.choices then
              -- Cycle enum
              local cur = tostring(v or "")
              local next_idx = 1
              for ci, cv in ipairs(mf.choices) do
                if cv == cur then
                  next_idx = ci + 1
                  break
                end
              end
              if next_idx > #mf.choices then next_idx = 1 end
              data.machines[data.editing_machine][mf.key] = mf.choices[next_idx]
            else
              data.edit_buffer = tostring(v or "")
              data.editing = true
              data.status_msg = nil
            end
          end
        elseif code == 15 then  -- Tab: next field
          data.machine_focus_field = data.machine_focus_field + 1
          if data.machine_focus_field > max_f then
            data.machine_focus_field = 1
          end
        end

      else
        -- Machine list view
        local max_m = data.machines and #data.machines or 0

        if code == 200 then  -- Up
          data.focus_field = math.max(1, data.focus_field - 1)
        elseif code == 208 then  -- Down
          data.focus_field = math.min(max_m, data.focus_field + 1)
        elseif code == 28 then  -- Enter: enter machine edit
          if max_m > 0 and data.focus_field >= 1 and data.focus_field <= max_m then
            data.editing_machine = data.focus_field
            data.machine_focus_field = 1
          end
        end
      end

      return
    end

    -- Non-machine sections: field navigation
    local fields = sec and sec.fields or {}
    local max_f = #fields

    if code == 200 then  -- Up
      data.focus_field = math.max(1, data.focus_field - 1)

    elseif code == 208 then  -- Down
      data.focus_field = math.min(max_f, data.focus_field + 1)

    elseif code == 15 then  -- Tab: next field, wrap to next section
      data.focus_field = data.focus_field + 1
      if data.focus_field > max_f then
        data.focus_field = 1
        data.focus_section = data.focus_section + 1
        if data.focus_section > #data.sections then
          data.focus_section = 1
        end
      end

    elseif code == 28 then  -- Enter: edit / toggle / cycle
      local f = fields[data.focus_field]
      if f then
        if f.type == "boolean" then
          f.value = not f.value
          data.status_msg = f.label .. " = " .. tostring(f.value)
        elseif f.type == "enum" and f.choices then
          -- Cycle to next choice
          local cur = tostring(f.value or "")
          local next_idx = 1
          for ci, cv in ipairs(f.choices) do
            if cv == cur then
              next_idx = ci + 1
              break
            end
          end
          if next_idx > #f.choices then next_idx = 1 end
          f.value = f.choices[next_idx]
          data.status_msg = f.label .. " = " .. tostring(f.value)
        else
          data.edit_buffer = tostring(f.value or "")
          data.editing = true
          data.status_msg = nil
        end
      end

    -- Number keys 2-8: jump to section (sections 1-7)
    elseif code >= 50 and code <= 56 then
      local idx = code - 49  -- '2'=1, '3'=2, ... '8'=7
      if idx >= 1 and idx <= #data.sections then
        data.focus_section = idx
        data.focus_field = 1
        data.editing_machine = nil
      end
    end

    return
  end

  -----------------------------------------------------------------------
  -- EDITING mode
  -----------------------------------------------------------------------
  if code == 28 then  -- Enter: commit
    module._commit_edit(data)

  elseif code == 1 then  -- Escape: cancel
    data.editing = false
    data.edit_buffer = ""

  elseif code == 14 then  -- Backspace
    if #data.edit_buffer > 0 then
      data.edit_buffer = string.sub(data.edit_buffer, 1, -2)
    end

  -- Printable ASCII range
  elseif code >= 32 and code <= 126 then
    local char = string.char(code)
    -- Filter for number fields
    local f = get_current_field(data)
    if f and f.type == "number" then
      if char == "-" or char == "." or (char >= "0" and char <= "9") then
        -- Only allow one minus sign at start
        if char == "-" then
          if #data.edit_buffer == 0 then
            data.edit_buffer = data.edit_buffer .. char
          end
        else
          data.edit_buffer = data.edit_buffer .. char
        end
      end
    else
      data.edit_buffer = data.edit_buffer .. char
    end
  end
end

-- Commit the current edit (Enter during editing)
function module._commit_edit(data)
  local sec = data.sections[data.focus_section]
  local f = get_current_field(data)
  if not f then
    data.editing = false
    data.edit_buffer = ""
    return
  end

  local raw = data.edit_buffer
  if f.type == "number" then
    if f.nullable and (raw == "" or raw == "nil") then
      data.editing = false
      data.edit_buffer = ""
      set_current_value(data, nil)
      data.status_msg = f.label .. " = nil"
      return
    end
    local ok, result = validate_field(f, raw)
    if not ok then
      data.status_msg = "Invalid: " .. tostring(result)
      return
    end
    set_current_value(data, result)
    data.status_msg = f.label .. " = " .. tostring(result)
  elseif f.type == "enum" then
    local ok, result = validate_field(f, raw)
    if not ok then
      data.status_msg = "Invalid: " .. tostring(result)
      -- Don't cancel edit; let user correct
      return
    end
    set_current_value(data, result)
    data.status_msg = f.label .. " = " .. tostring(result)
  else
    -- string
    set_current_value(data, raw)
    data.status_msg = f.label .. " updated"
  end

  data.editing = false
  data.edit_buffer = ""
end

return module
