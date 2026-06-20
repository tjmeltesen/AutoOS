-- broker_ui_config.lua - Config editor page for AutoOS Broker UI
-- Lua 5.2, OpenComputers. Self-sufficient: builds config data from file if not provided.

local module = { name = "Config" }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function load_cfg(path)
  local ok, cfg = pcall(dofile, path or "config.lua")
  if ok and type(cfg) == "table" then return cfg end
  return nil
end

local function sval(v)
  if v == nil then return "nil"
  elseif type(v) == "boolean" then return v and "true" or "false"
  else return tostring(v) end
end

---------------------------------------------------------------------------
-- Field definitions for all 7 sections
---------------------------------------------------------------------------
local function build_sections(cfg)
  cfg = cfg or {}
  local sc = cfg.scheduler or {}
  local ct = cfg.central or {}

  return {
    { name = "Network", fields = {
      {l="Subnet ID",       k="subnet_id",              v=cfg.subnet_id or "",               t="string"},
      {l="Modem Port",        k="broker_modem_port",      v=cfg.broker_modem_port or 106,       t="number", min=1, max=65535},
      {l="Main Channel",      k="main_net_channel",       v=cfg.main_net_channel or 105,        t="number", min=1, max=65535},
      {l="Orchestrator Addr", k="orchestrator_address",   v=cfg.orchestrator_address or "",     t="string"},
    }},
    { name = "Mode & Timing", fields = {
      {l="Input Mode",         k="input_mode",          v=cfg.input_mode or "central",              t="enum", choices={"per_lane","central"}},
      {l="Completion Mode",    k="completion_mode",     v=cfg.completion_mode or "both",            t="enum", choices={"both","adapter","drain"}},
      {l="Round Robin",        k="do_round_robin",      v=cfg.do_round_robin ~= false,              t="boolean"},
      {l="Tick Interval (s)",  k="tick_interval",       v=cfg.tick_interval or 1.0,                 t="number", min=0.01},
      {l="Settle (s)",         k="settle_s",             v=cfg.settle_s or 0.1,                      t="number", min=0},
      {l="Monitor Poll (s)",   k="monitor_poll_s",       v=cfg.monitor_poll_s or 0.15,               t="number", min=0.01},
      {l="Staging Timeout (s)",k="staging_timeout_s",    v=cfg.staging_timeout_s or 60.0,            t="number", min=0},
      {l="Completion TO (s)",  k="completion_timeout_s", v=cfg.completion_timeout_s or 300.0,        t="number", min=0},
      {l="Req Empty Return",   k="require_empty_return", v=cfg.require_empty_return ~= false,        t="boolean"},
    }},
    { name = "AE2 & Database", fields = {
      {l="Database Address",     k="database_address",          v=cfg.database_address or "",              t="string"},
      {l="DB Slot Count",        k="database_slot_count",       v=cfg.database_slot_count or 9,            t="number", min=1},
      {l="IF Item Slots",        k="interface_item_slots",      v=cfg.interface_item_slots or 9,           t="number", min=1},
      {l="IF Slot Start",        k="interface_item_slot_start", v=cfg.interface_item_slot_start or 1,      t="number", min=1},
      {l="IF Fluid Side",        k="interface_fluid_side",      v=cfg.interface_fluid_side or 0,           t="number", min=0, max=5},
      {l="Shared IF Address",    k="shared_interface_address",  v=cfg.shared_interface_address or "",     t="string"},
      {l="Chest Slot Start",     k="chest_slot_start",          v=cfg.chest_slot_start or 1,              t="number", min=1},
      {l="Circuit Bus Slot",     k="circuit_bus_slot",           v=cfg.circuit_bus_slot or 1,               t="number", min=1},
      {l="Circuit Item Name",    k="circuit_item_name",         v=cfg.circuit_item_name or "gregtech:gt.integrated_circuit", t="string"},
    }},
    { name = "Redstone Lock", fields = {
      {l="RS Address",       k="redstone_address",  v=cfg.redstone_address or "",         t="string"},
      {l="RS Side",          k="redstone_side",     v=cfg.redstone_side or 0,            t="number", min=0, max=5},
      {l="Pulse Duration (s)",k="redstone_pulse_s",  v=cfg.redstone_pulse_s or 0.5,        t="number", min=0},
    }},
    { name = "Scheduler", table_key = "scheduler", fields = {
      {l="Max Parallel Lanes", k="max_parallel_lanes", v=sc.max_parallel_lanes,                t="number", min=1, nullable=true},
      {l="Max Job Attempts",   k="max_job_attempts",    v=sc.max_job_attempts or 2,              t="number", min=1},
      {l="Watchdog Grace (s)", k="watchdog_grace_s",    v=sc.watchdog_grace_s or 10,             t="number", min=0},
      {l="Persist Jobs",       k="persist_jobs",        v=sc.persist_jobs or "startup_sweep",    t="enum", choices={"startup_sweep","file"}},
      {l="Active Lane Budget", k="active_lane_budget",  v=sc.active_lane_budget or 32,           t="number", min=1},
    }},
    { name = "Central Buffer", table_key = "central", fields = {
      {l="Monitor Mode",           k="monitor",                   v=ct.monitor or "inventory_controller",  t="enum", choices={"inventory_controller","adapter"}},
      {l="IC Side",                k="inventory_controller_side", v=ct.inventory_controller_side or 0,     t="number", min=0, max=5},
      {l="Buffer Adapter Addr",    k="buffer_adapter_address",    v=ct.buffer_adapter_address or "",       t="string"},
      {l="Buffer Adapter Side",    k="buffer_adapter_side",       v=ct.buffer_adapter_side or 0,           t="number", min=0, max=5},
      {l="Fluid Adapter Addr",     k="fluid_adapter_address",     v=ct.fluid_adapter_address or "",        t="string"},
      {l="Fluid Adapter Side",     k="fluid_adapter_side",        v=ct.fluid_adapter_side or 0,            t="number", min=0, max=5},
      {l="Chest Slot Start",       k="chest_slot_start",          v=ct.chest_slot_start or 1,              t="number", min=1},
      {l="Max Circuits In Buffer", k="max_circuits_in_buffer",    v=ct.max_circuits_in_buffer or 1,        t="number", min=1},
      {l="Ingest Mode",            k="ingest_mode",               v=ct.ingest_mode or "event_or_poll",      t="enum", choices={"event_or_poll","event","poll"}},
      {l="Job Stabilize (s)",      k="job_stabilize_s",           v=ct.job_stabilize_s or 1.0,             t="number", min=0},
      {l="Stabilize (s)",          k="stabilize_s",                v=ct.stabilize_s or 1.0,                 t="number", min=0},
      {l="Settle (s)",             k="settle_s",                   v=ct.settle_s or 0.0,                    t="number", min=0},
      {l="Interface Wait (s)",     k="interface_wait_s",          v=ct.interface_wait_s or 5.0,            t="number", min=0},
      {l="Require IF Staging",     k="require_interface_staging", v=ct.require_interface_staging or false,  t="boolean"},
    }},
    { name = "Machines", machines = true, fields = {
      {l="ID",                   k="id",                      t="string"},
      {l="GT Address",           k="gt_address",              t="string"},
      {l="Interface Address",    k="interface_address",       t="string"},
      {l="Item TP Address",      k="item_transposer_address", t="string"},
      {l="Fluid TP Address",     k="fluid_transposer_address",t="string"},
      {l="Side Buffer",          k="side_buffer",             t="number", min=0, max=5},
      {l="Side Bus B",           k="side_bus_b",              t="number", min=0, max=5},
      {l="Side Return",          k="side_return",             t="number", min=0, max=5},
      {l="Side Fluid Buffer",    k="side_fluid_buffer",       t="number", min=0, max=5},
      {l="Side Fluid Hatch",     k="side_fluid_hatch",        t="number", min=0, max=5},
      {l="Input Slot",           k="input_slot",              t="number", min=1},
    }},
  }
end

---------------------------------------------------------------------------
-- Build data on the fly from config file
---------------------------------------------------------------------------
function module.build_data(config_path)
  config_path = config_path or "subnet_broker/config.lua"
  local cfg = load_cfg(config_path)
  return {
    sections = build_sections(cfg),
    focus_section = 1, focus_field = 1,
    editing = false, edit_buffer = "",
    status_msg = nil, config_path = config_path,
    editing_machine = nil, machine_focus_field = 1,
    machines = cfg and cfg.machines or {},
  }
end

---------------------------------------------------------------------------
-- Simple config serializer
---------------------------------------------------------------------------
local function serialize_config(data)
  local lines = {"-- AutoOS Broker Config", "local Config = {}", ""}
  local top_order = {
    "subnet_id","main_net_channel","input_mode","completion_mode","do_round_robin",
    "circuit_item_name","database_address","database_slot_count","interface_item_slots",
    "interface_item_slot_start","interface_fluid_side","shared_interface_address",
    "chest_slot_start","circuit_bus_slot","settle_s","tick_interval","monitor_poll_s",
    "staging_timeout_s","completion_timeout_s","require_empty_return","orchestrator_address",
    "broker_modem_port","redstone_address","redstone_side","redstone_pulse_s",
  }
  for _, k in ipairs(top_order) do
    if data[k] ~= nil then lines[#lines+1] = "Config."..k.." = "..sval(data[k]) end
  end

  for _, sk in ipairs({"scheduler","central"}) do
    local sub = data[sk] or {}
    lines[#lines+1] = "\nConfig."..sk.." = {"
    for k, v in pairs(sub) do
      lines[#lines+1] = "  "..k.." = "..sval(v)..","
    end
    lines[#lines+1] = "}"
  end

  local machines = data.machines or {}
  lines[#lines+1] = "\nConfig.machines = {"
  for _, m in ipairs(machines) do
    lines[#lines+1] = "  {"
    for k, v in pairs(m) do
      lines[#lines+1] = "    "..k.." = "..sval(v)..","
    end
    lines[#lines+1] = "  },"
  end
  lines[#lines+1] = "}\n\nreturn Config"
  return table.concat(lines, "\n")
end

function module.save_config(data, config_path)
  config_path = config_path or data.config_path or "subnet_broker/config.lua"
  local f, err = io.open(config_path, "w")
  if not f then data.status_msg = "Error: " .. tostring(err); return false end
  f:write(serialize_config(data))
  f:close()
  data.status_msg = "Saved OK"
  return true
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------
function module.render(gpu, w, h, data)
  data = data or {}
  -- Self-build if sections missing
  if not data.sections or #data.sections == 0 then
    data = module.build_data(data.config_path or "subnet_broker/config.lua")
    -- Merge existing state (focus, editing, etc.) if possible
  end
  if not data.sections or #data.sections == 0 then
    gpu.setBackground(0x000000); gpu.fill(1, 1, w, h, " ")
    gpu.setForeground(0xFF0000)
    gpu.set(2, 2, "Config not available")
    gpu.set(2, 3, "Ensure config.lua exists")
    return
  end

  local sections = data.sections
  local fs = (data.focus_section or 1)
  local ff = (data.focus_field or 1)
  fs = math.min(math.max(1, fs), #sections)
  local sec = sections[fs]
  if not sec then sec = sections[1]; data.focus_section = 1 end
  local fields = sec.fields or {}
  if ff > #fields then ff = 1; data.focus_field = 1 end

  gpu.setBackground(0x000000)
  gpu.fill(1, 1, w, h, " ")

  -- Row 1: header
  gpu.setForeground(0x808080)
  local hdr = " Config: " .. (data.config_path or "config.lua") .. "  [Ctrl+S:Save]"
  if #hdr > w then hdr = hdr:sub(1, w) end
  gpu.set(1, 1, hdr)

  -- Two-column layout
  local left_w = math.floor(w * 0.35)
  if left_w < 10 then left_w = 10 end

  -- Left: section list
  for i, s in ipairs(sections) do
    if i > h - 3 then break end
    if i == fs then gpu.setForeground(0xFFFFFF)
    else gpu.setForeground(0x808080) end
    local label = string.format(" %d.%-20s", i, s.name)
    gpu.set(1, i + 1, label:sub(1, left_w))
  end

  -- Right: fields
  local right_x = left_w + 2
  local right_w = w - left_w - 1
  gpu.setForeground(0xFFFF00)
  gpu.set(right_x, 2, sec.name)
  gpu.setForeground(0x808080)
  gpu.set(right_x, 3, string.rep("-", right_w))

  local row = 4
  local max_fr = h - 3
  for i = 1, math.min(#fields, max_fr) do
    if row > h - 2 then break end
    local f = fields[i]
    local val = data.editing and i == ff and (data.edit_buffer .. "_") or sval(f.v)
    local label = f.l
    if #label > 20 then label = label:sub(1, 19) .. "." end
    local line = string.format(" %-21s %s", label, val)
    if #line > right_w then line = line:sub(1, right_w) end
    if i == ff then gpu.setForeground(0x00FFFF)
    else gpu.setForeground(0xFFFFFF) end
    gpu.set(right_x, row, line)
    row = row + 1
  end

  -- Machines section: show list
  if sec.machines then
    gpu.setForeground(0x808080)
    gpu.set(right_x, row, "  Machines: " .. #(data.machines or {}))
    row = row + 1
    local machines = data.machines or {}
    for i = 1, math.min(#machines, h - row) do
      local m = machines[i]
      local mid = m.id or ("#" .. i)
      gpu.setForeground(i == ff and 0x00FFFF or 0xFFFFFF)
      gpu.set(right_x, row, string.format(" %d. %s", i, mid):sub(1, right_w))
      row = row + 1
    end
  end

  -- Status message
  if data.status_msg then
    gpu.setForeground(data.status_msg:find("Error") and 0xFF0000 or 0x00FF00)
    gpu.set(1, h - 1, data.status_msg:sub(1, w))
  end

  -- Help
  local help = "Up/Dn:nav  Enter:edit  Tab:next  Esc:cancel  Ctrl+S:save  1-7:section"
  if data.editing then help = "EDITING - Enter:commit  Esc:cancel  Bksp:delete" end
  gpu.setForeground(0x404040)
  gpu.set(1, h, help:sub(1, w))

  data._h = h; data._w = w
end

---------------------------------------------------------------------------
-- Key handling
---------------------------------------------------------------------------
function module.handle_key(code, data)
  data = data or {}
  data.sections = data.sections or {}
  data.machines = data.machines or {}
  local fs = data.focus_section or 1
  local sec = data.sections[fs]
  local fields = (sec and sec.fields) or {}
  local ff = data.focus_field or 1

  -- Ctrl+S save
  if code == 31 then
    if data.editing then data.editing = false; data.edit_buffer = "" end
    module.save_config(data)
    return
  end

  -- Escape: cancel edit
  if code == 1 then
    data.editing = false; data.edit_buffer = ""; return
  end

  if not data.editing then
    -- Navigation mode
    if code == 200 then data.focus_field = math.max(1, ff - 1)        -- Up
    elseif code == 208 then data.focus_field = math.min(#fields, ff + 1) -- Down
    elseif code == 15 then  -- Tab: next field, wrap sections
      data.focus_field = ff + 1
      if data.focus_field > #fields then
        data.focus_field = 1
        data.focus_section = fs + 1
        if data.focus_section > #data.sections then data.focus_section = 1 end
      end
    elseif code == 28 then  -- Enter: edit/toggle/cycle
      local f = fields[ff]
      if f then
        if f.t == "boolean" then f.v = not f.v
        elseif f.t == "enum" and f.choices then
          local cur = sval(f.v or f.choices[1])
          for ci, cv in ipairs(f.choices) do
            if cv == cur then
              f.v = f.choices[(ci % #f.choices) + 1]; break
            end
          end
        else
          data.edit_buffer = sval(f.v or "")
          data.editing = true; data.status_msg = nil
        end
      end
    -- Number keys 2-8: jump sections
    elseif code >= 50 and code <= 56 then
      local idx = code - 49
      if idx <= #data.sections then data.focus_section = idx; data.focus_field = 1 end
    end
  else
    -- Editing mode
    local f = fields[ff]
    if code == 28 then  -- Enter: commit
      if f then
        if f.t == "number" then
          local n = tonumber(data.edit_buffer)
          if n then f.v = n; data.status_msg = f.l.." = "..sval(n)
          else data.status_msg = "Invalid number" end
        else f.v = data.edit_buffer; data.status_msg = f.l.." updated" end
      end
      data.editing = false; data.edit_buffer = ""
    elseif code == 14 then  -- Backspace
      data.edit_buffer = data.edit_buffer:sub(1, -2)
    elseif code >= 32 and code <= 126 then  -- Printable
      local ch = string.char(code)
      if f and f.t == "number" then
        if (ch >= "0" and ch <= "9") or ch == "." or (ch == "-" and #data.edit_buffer == 0) then
          data.edit_buffer = data.edit_buffer .. ch
        end
      else
        data.edit_buffer = data.edit_buffer .. ch
      end
    end
  end
end

return module
