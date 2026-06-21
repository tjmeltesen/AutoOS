-- broker_ui.lua - AutoOS Broker TUI (single-file, no page dependencies)
-- Lua 5.2, OpenComputers.
local BrokerUI = {}; BrokerUI.__index = BrokerUI

local LOG_PATH = "/home/subnet_broker/lane_worker.log"

-- Safe GPU wrappers (pcall all calls — don't crash the UI on GPU errors)
local function FG(g, c) if g and c then pcall(g.setForeground, c) end end
local function GS(g, x, y, s) if g and x and y and s then pcall(g.set, x, y, tostring(s)) end end
local function FL(g, x, y, w2, h2, ch) if g and x and y and w2 and h2 then pcall(g.fill, x, y, w2, h2, ch or " ") end end

local function fmtt(sec)
  if not sec or sec < 0 then return "--" end
  if sec < 60 then return "<1m" end
  local d, h, m, s = math.floor(sec/86400), math.floor((sec%86400)/3600), math.floor((sec%3600)/60), math.floor(sec%60)
  if d > 0 then return string.format("%dd%dh", d, h) end
  if h > 0 then return string.format("%dh%dm", h, m) end
  if s > 0 then return string.format("%dm%ds", m, s) end
  return string.format("%dm", m)
end

local function fmtag(now, t)
  if not now or not t then return "--" end
  local d = now - t; if d < 0 then return "--" end
  if d < 60 then return math.floor(d).."s" elseif d < 3600 then return math.floor(d/60).."m" else return math.floor(d/3600).."h" end
end

-- Colors (hex, supported on all OC GPU tiers ≥ 2; tier 1 uses palette, still works)
local G, W, Y, R, GRAY, CYAN = 0x00FF00, 0xFFFFFF, 0xFFFF00, 0xFF0000, 0x808080, 0x00FFFF

-----------------------------------------------------------------------
-- Dashboard renderer
-----------------------------------------------------------------------
local function render_dashboard(gpu, w, h, data)
  data = data or {}
  local lanes = data.lanes or {}
  local pending = data.pending or {}
  local locks = data.locks or {}
  local now = data.now_fn and data.now_fn() or 0
  FL(gpu, 1, 1, w, h, " ")

  -- Row 1: title
  FG(gpu, GRAY); GS(gpu, 1, 1, (" AutoOS Broker -- %s"):format(data.subnet_id or "?"):sub(1, w))

  -- Row 2: broker state + uptime + port + jobs
  local active, faulted = 0, 0
  for _, l in pairs(lanes) do
    if l.state == "WORKING" then active = active + 1 elseif l.state == "FAULTED" then faulted = faulted + 1 end
  end
  local bstate = data.broker_active and "RUNNING" or "STOPPED"
  FG(gpu, GRAY)
  GS(gpu, 1, 2, (" BROKER: %-8s  Uptime: %-6s  Port: %-3s  Jobs: %s"):format(
    bstate, fmtt(data.uptime or 0), tostring(data.port or "?"), tostring(active).."/"..tostring(data.max_lanes or 0)):sub(1, w))
  FG(gpu, data.broker_active and G or R); GS(gpu, 9, 2, bstate)

  -- Row 3: status message (if any)
  if data.status then FG(gpu, CYAN); GS(gpu, 1, 3, data.status:sub(1, w)) end
  local next_row = data.status and 4 or 3
  -- Separator
  FG(gpu, GRAY); GS(gpu, 1, next_row, string.rep("-", w))

  -- Lane Status
  local r = next_row + 1; FG(gpu, GRAY); GS(gpu, 1, r, " Lane Status"); r = r + 1
  GS(gpu, 1, r, (" %-14s %-9s %-18s %s"):format("Machine","State","Job","Elapsed")); r = r + 1
  local keys = {}; for k in pairs(lanes) do keys[#keys+1] = k end; table.sort(keys)
  local off = data.scroll_offset or 0; local maxo = math.max(0, #keys - 6)
  if off < 0 then off = 0 elseif off > maxo then off = maxo end
  data.scroll_offset = off
  for li = 1 + off, math.min(off + 6, #keys) do
    if r > h - 6 then break end
    local k = keys[li]; local l = lanes[k] or {}; local s = l.state or "?"
    local lc = (s=="WORKING" and Y or s=="FAULTED" and R or s=="IDLE" and G or W)
    local nm = #k > 14 and k:sub(1,13).."." or (k..string.rep(" ", 14 - #k))
    local j = l.current_job_id or (s=="FAULTED" and (l.last_error or "?")) or "--"
    if #j > 17 then j = j:sub(1,16).."." end
    j = j..string.rep(" ", 18 - #j)
    local el = "--"; if s=="WORKING" and l.state_entered_at then el = fmtt(now - l.state_entered_at) end
    FG(gpu, GRAY); GS(gpu, 1, r, (" %-14s "):format(nm))
    FG(gpu, lc); GS(gpu, 17, r, (s..string.rep(" ", 9)):sub(1, 9))
    FG(gpu, W); GS(gpu, 27, r, j)
    FG(gpu, GRAY); GS(gpu, 46, r, el); r = r + 1
  end
  if #keys == 0 then FG(gpu, GRAY); GS(gpu, 1, r, " (no lanes)"); r = r + 1 end

  -- Pending Queue
  r = r + 1; FG(gpu, GRAY); GS(gpu, 1, r, " Pending Queue"); r = r + 1
  if #pending == 0 then FG(gpu, GRAY); GS(gpu, 1, r, " (empty)"); r = r + 1
  else
    for i = 1, math.min(#pending, 3) do
      if r > h - 4 then break end
      local jb = pending[i] or {}
      local it = (jb.manifest and jb.manifest.items and #jb.manifest.items) or 0
      local fl = (jb.manifest and jb.manifest.fluids and #jb.manifest.fluids) or 0
      FG(gpu, W); GS(gpu, 1, r, (" %-20s  age:%-5s  a:%d  %di/%df"):format(
        (jb.id or "?"):sub(1,20), fmtag(now, jb.created_at), jb.attempt or 1, it, fl):sub(1, w)); r = r + 1
    end
  end

  -- Active Locks
  r = r + 1; FG(gpu, GRAY); GS(gpu, 1, r, " Active Locks"); r = r + 1
  local lkeys = {}; for k in pairs(locks) do lkeys[#lkeys+1] = k end
  if #lkeys == 0 then FG(gpu, GRAY); GS(gpu, 1, r, " (none)"); r = r + 1
  else
    for i = 1, math.min(#lkeys, 3) do
      if r > h - 1 then break end
      local key = lkeys[i]; local disp = key:gsub(":(%x%x%x%x%x%x%x%x)%-[%x%-]+", ":%1...")
      if #disp > 45 then disp = disp:sub(1,44).."." end
      FG(gpu, W); GS(gpu, 1, r, (" %-47s  %s"):format(disp, locks[key] or "?"):sub(1, w)); r = r + 1
    end
  end
  FG(gpu, GRAY); GS(gpu, 1, h, "[1]Dash  [2]Logs  [3]Config  S:start/stop  Q:quit  Up/Dn:scroll")
end

-----------------------------------------------------------------------
-- Logs renderer
-----------------------------------------------------------------------
local function render_logs(gpu, w, h, data)
  data = data or {}
  local path = data.path or LOG_PATH
  local lines = data.lines; if type(lines) ~= "table" then lines = {} end
  local offset = data.offset or 0; local follow = data.follow
  FL(gpu, 1, 1, w, h, " ")
  if follow then offset = 0; data.offset = 0 end
  FG(gpu, GRAY); GS(gpu, 1, 1, ("--- Logs: %s"):format(path or "?"):sub(1, w))
  if #lines == 0 then
    FG(gpu, GRAY); GS(gpu, math.floor((w - 12)/2)+1, math.floor(h/2), "(no log data)")
    data._h = h; data._w = w; return
  end
  local vis = h - 2; if vis < 1 then vis = 1 end
  local ei = #lines - offset; if ei < 1 then ei = #lines elseif ei > #lines then ei = #lines end
  local si = ei - vis + 1; if si < 1 then si = 1 end
  for i = si, ei do
    local lr = 2 + i - si; if lr > h then break end
    local line = lines[i] or ""
    local lc = W
    if line:find("FAILED", 1, true) or line:find("ERROR", 1, true) then lc = R
    elseif line:find("Phase", 1, true) then lc = Y
    elseif line:find("dispatched", 1, true) then lc = G end
    FG(gpu, lc); GS(gpu, 1, lr, line:sub(1, w))
  end
  local sr = h
  FG(gpu, follow and CYAN or GRAY); GS(gpu, 1, sr, follow and "[Follow:ON]" or "[Follow:OFF]")
  FG(gpu, GRAY); local cnt = ("L%d/%d"):format(ei, #lines); GS(gpu, w - #cnt, sr, cnt)
  data._h = h; data._w = w
end

-----------------------------------------------------------------------
-- Config renderer
-----------------------------------------------------------------------
local function serialize_config(cfg)
  local function sv(v)
    if v == nil then return "nil"
    elseif type(v) == "boolean" then return v and "true" or "false"
    elseif type(v) == "number" then return tostring(v)
    else return string.format("%q", v) end
  end
  local l = {"-- AutoOS Broker Config (UI-generated)", "local Config = {}", ""}
  local top = {"subnet_id","main_net_channel","input_mode","completion_mode","do_round_robin",
    "circuit_item_name","database_address","database_slot_count","interface_item_slots",
    "interface_item_slot_start","interface_fluid_side","shared_interface_address",
    "chest_slot_start","circuit_bus_slot","settle_s","tick_interval","monitor_poll_s",
    "staging_timeout_s","completion_timeout_s","require_empty_return","orchestrator_address",
    "broker_modem_port","redstone_address","redstone_side","redstone_pulse_s"}
  for _,k in ipairs(top) do if cfg[k] ~= nil then l[#l+1] = "Config."..k.." = "..sv(cfg[k]) end end
  for _,sk in ipairs({"scheduler","central"}) do
    local sub = cfg[sk] or {}; l[#l+1] = "\nConfig."..sk.." = {"
    for k,v in pairs(sub) do l[#l+1] = "  "..k.." = "..sv(v).."," end
    l[#l+1] = "}"
  end
  local machines = cfg.machines or {}; l[#l+1] = "\nConfig.machines = {"
  for _,m in ipairs(machines) do
    l[#l+1] = "  {"
    for k,v in pairs(m) do l[#l+1] = "    "..k.." = "..sv(v).."," end
    l[#l+1] = "  },"
  end
  l[#l+1] = "}\n\nreturn Config"; return table.concat(l, "\n")
end

local function render_config(gpu, w, h, data)
  data = data or {}
  -- Build sections once
  if not data._sections or #data._sections == 0 then
    local cfg = {}
    if not data._cfg then
      local ok, c = pcall(dofile, "/home/subnet_broker/config.lua")
      if ok and type(c) == "table" then data._cfg = c; cfg = c end
    else cfg = data._cfg end
    local sc, ct = cfg.scheduler or {}, cfg.central or {}
    data._sections = {
      {n="Network", f={
        {l="Subnet ID",       v=cfg.subnet_id or "",               t="s"},
        {l="Modem Port",       v=cfg.broker_modem_port or 106,      t="n", min=1, max=65535},
        {l="Main Channel",     v=cfg.main_net_channel or 105,       t="n", min=1, max=65535},
        {l="Orch Addr",        v=cfg.orchestrator_address or "",    t="s"},
      }},
      {n="Mode & Timing", f={
        {l="Input Mode",        v=cfg.input_mode or "central",      t="e", c={"per_lane","central"}},
        {l="Completion Mode",   v=cfg.completion_mode or "both",    t="e", c={"both","adapter","drain"}},
        {l="Round Robin",       v=cfg.do_round_robin~=false,        t="b"},
        {l="Tick Interval (s)",  v=cfg.tick_interval or 1.0,        t="n", min=0.01},
        {l="Settle (s)",        v=cfg.settle_s or 0.1,              t="n", min=0},
        {l="Monitor Poll (s)",  v=cfg.monitor_poll_s or 0.15,       t="n", min=0.01},
        {l="Staging Timeout",   v=cfg.staging_timeout_s or 60,      t="n", min=0},
        {l="Completion TO",     v=cfg.completion_timeout_s or 300,  t="n", min=0},
        {l="Req Empty Return",  v=cfg.require_empty_return~=false,  t="b"},
      }},
      {n="AE2 & Database", f={
        {l="DB Address",        v=cfg.database_address or "",       t="s"},
        {l="DB Slot Count",     v=cfg.database_slot_count or 9,     t="n", min=1},
        {l="IF Item Slots",     v=cfg.interface_item_slots or 9,    t="n", min=1},
        {l="IF Slot Start",     v=cfg.interface_item_slot_start or 1,t="n", min=1},
        {l="IF Fluid Side",     v=cfg.interface_fluid_side or 0,    t="n", min=0, max=5},
        {l="Shared IF Addr",    v=cfg.shared_interface_address or "",t="s"},
        {l="Chest Slot Start",  v=cfg.chest_slot_start or 1,        t="n", min=1},
        {l="Circuit Bus Slot",  v=cfg.circuit_bus_slot or 1,        t="n", min=1},
        {l="Circuit Item",      v=cfg.circuit_item_name or "gregtech:gt.integrated_circuit", t="s"},
      }},
      {n="Redstone Lock", f={
        {l="RS Address",        v=cfg.redstone_address or "",       t="s"},
        {l="RS Side",           v=cfg.redstone_side or 0,           t="n", min=0, max=5},
        {l="Pulse Duration",    v=cfg.redstone_pulse_s or 0.5,      t="n", min=0},
      }},
      {n="Scheduler", f={
        {l="Max Parallel",      v=sc.max_parallel_lanes,            t="n", min=1, nilok=true},
        {l="Max Job Attempts",  v=sc.max_job_attempts or 2,         t="n", min=1},
        {l="Watchdog Grace",    v=sc.watchdog_grace_s or 10,        t="n", min=0},
        {l="Persist Jobs",      v=sc.persist_jobs or "startup_sweep", t="e", c={"startup_sweep","file"}},
        {l="Lane Budget",       v=sc.active_lane_budget or 32,      t="n", min=1},
      }},
      {n="Central Buffer", f={
        {l="Monitor Mode",      v=ct.monitor or "inventory_controller", t="e", c={"inventory_controller","adapter"}},
        {l="IC Side",           v=ct.inventory_controller_side or 0, t="n", min=0, max=5},
        {l="Buffer Adapter",    v=ct.buffer_adapter_address or "",   t="s"},
        {l="Buffer Side",       v=ct.buffer_adapter_side or 0,       t="n", min=0, max=5},
        {l="Fluid Adapter",     v=ct.fluid_adapter_address or "",    t="s"},
        {l="Fluid Side",        v=ct.fluid_adapter_side or 0,        t="n", min=0, max=5},
        {l="Chest Slot Start",  v=ct.chest_slot_start or 1,          t="n", min=1},
        {l="Max Circuits",      v=ct.max_circuits_in_buffer or 1,    t="n", min=1},
        {l="Ingest Mode",       v=ct.ingest_mode or "event_or_poll", t="e", c={"event_or_poll","event","poll"}},
        {l="Job Stabilize",     v=ct.job_stabilize_s or 1.0,        t="n", min=0},
        {l="Stabilize",         v=ct.stabilize_s or 1.0,             t="n", min=0},
        {l="Settle",            v=ct.settle_s or 0.0,                t="n", min=0},
        {l="IF Wait",           v=ct.interface_wait_s or 5.0,        t="n", min=0},
        {l="Req IF Staging",    v=ct.require_interface_staging or false, t="b"},
      }},
      {n="Machines", ismach=true, f={
        {l="ID",                t="s"}, {l="GT Address", t="s"}, {l="IF Address", t="s"},
        {l="Item TP Addr",      t="s"}, {l="Fluid TP Addr", t="s"},
        {l="Side Buffer",       t="n", min=0, max=5}, {l="Side Bus B", t="n", min=0, max=5},
        {l="Side Return",       t="n", min=0, max=5}, {l="Side Fluid Buffer", t="n", min=0, max=5},
        {l="Side Fluid Hatch",  t="n", min=0, max=5}, {l="Input Slot", t="n", min=1},
      }},
    }
    if not data._machines then data._machines = cfg.machines or {} end
    if not data._fs then data._fs = 1 end
    if not data._ff then data._ff = 1 end
    if not data._editing then data._editing = false end
    if not data._eb then data._eb = "" end
  end

  local sections = data._sections
  if not sections or #sections == 0 then FG(gpu,R);GS(gpu,2,2,"Config unavailable");return end
  local fs = data._fs or 1; if fs < 1 then fs = 1 elseif fs > #sections then fs = #sections end
  data._fs = fs
  local sec = sections[fs] or sections[1]
  if not sec then FG(gpu,R);GS(gpu,2,2,"Config section error");return end
  local fields = sec.f or {}
  local ff = data._ff or 1; if ff < 1 then ff = 1 elseif ff > #fields then ff = #fields end
  data._ff = ff

  FL(gpu, 1, 1, w, h, " ")
  FG(gpu, GRAY); GS(gpu, 1, 1, (" Config: subnet_broker/config.lua  [Ctrl+S:Save]"):sub(1, w))

  -- Left pane: sections
  local lw = math.floor(w * 0.35); if lw < 10 then lw = 10 end
  for i, s in ipairs(sections) do
    if i > h - 3 then break end
    FG(gpu, i == fs and W or GRAY)
    GS(gpu, 1, i + 1, (" %d.%s"):format(i, s.n .. string.rep(" ", 22 - #s.n)):sub(1, lw))
  end

  -- Right pane: fields
  local rx, rw = lw + 2, w - lw - 1
  FG(gpu, Y); GS(gpu, rx, 2, sec.n)
  FG(gpu, GRAY); GS(gpu, rx, 3, string.rep("-", rw))
  local row = 4
  for i = 1, math.min(#fields, h - 3) do
    if row > h - 2 then break end
    local f = fields[i]
    local val = (data._editing and i == ff) and (data._eb or "").."_" or tostring(f.v or "")
    if f.t == "b" and not data._editing then val = f.v and "true" or "false" end
    local lb = f.l; if #lb > 20 then lb = lb:sub(1,19).."." end
    FG(gpu, i == ff and CYAN or W); GS(gpu, rx, row, (" %-21s %s"):format(lb, val):sub(1, rw)); row = row + 1
  end
  -- Machines section
  if sec.ismach then
    FG(gpu, GRAY); GS(gpu, rx, row, (" Machines: %d"):format(#data._machines)); row = row + 1
    for i = 1, math.min(#data._machines, h - row) do
      local m = data._machines[i]; FG(gpu, i == ff and CYAN or W)
      GS(gpu, rx, row, (" %d. %s"):format(i, m.id or ("#"..i)):sub(1, rw)); row = row + 1
    end
  end
  -- Status + help
  if data._status then FG(gpu, data._status:find("Err") and R or G); GS(gpu, 1, h - 1, data._status:sub(1, w)) end
  FG(gpu, 0x404040)
  GS(gpu, 1, h, (data._editing and "EDIT: Enter=commit Bksp=delete" or "Up/Dn:field L/R:section Tab:next Enter:edit Ctrl+S:save 2-8:jump"):sub(1, w))
  data._h = h; data._w = w
end

-----------------------------------------------------------------------
-- Page key handlers
-----------------------------------------------------------------------
local function handle_dashboard_key(code, char, data)
  data = data or {}; local n = 0; for _ in pairs(data.lanes or {}) do n = n + 1 end
  local off = data.scroll_offset or 0
  if code == 200 then data.scroll_offset = math.max(0, off - 1)
  elseif code == 208 then data.scroll_offset = math.min(math.max(0, n - 6), off + 1) end
end

local function handle_logs_key(code, char, data)
  data = data or {}; data.lines = data.lines or {}; local hh = data._h or 20
  local mx = math.max(0, #data.lines - hh + 2)
  if code == 200 then data.offset = (data.offset or 0) + 1
  elseif code == 208 then data.offset = (data.offset or 0) - 1
  elseif code == 201 then data.offset = (data.offset or 0) + 10
  elseif code == 209 then data.offset = (data.offset or 0) - 10
  elseif code == 199 then data.offset = #data.lines
  elseif code == 207 then data.offset = 0
  elseif code == 57 then data.follow = not data.follow end
  if data.offset < 0 then data.offset = 0 elseif data.offset > mx then data.offset = mx end
end

local function handle_config_key(code, char, data)
  data = data or {}; data._sections = data._sections or {}; data._machines = data._machines or {}
  local secs = data._sections; if #secs == 0 then return end
  local fs = data._fs or 1; if fs < 1 then fs = 1 elseif fs > #secs then fs = #secs end
  data._fs = fs
  local sec = secs[fs] or {}; local fields = sec.f or {}; local ff = data._ff or 1
  if ff < 1 then ff = 1 elseif ff > #fields then ff = #fields end
  data._ff = ff

  -- Ctrl+S: _handle_key pre-checks Ctrl before routing here
  if code == 31 then
    if data._editing then data._editing = false; data._eb = "" end
    local out = data._cfg or {}
    for _, s in ipairs(data._sections or {}) do
      for _, f in ipairs(s.f or {}) do
        if f.k then out[f.k] = f.v end
      end
    end
    out.machines = data._machines
    local content = serialize_config(out)
    local f, err = io.open("/home/subnet_broker/config.lua", "w")
    if f then f:write(content); f:close(); data._status = "Saved OK — reboot to apply"
    else data._status = "Error: " .. tostring(err) end
    return
  end
  -- Backspace: delete last char (editing guaranteed by _handle_key routing)
  if code == 14 then data._eb = data._eb:sub(1, -2); return end

  if not data._editing then
    if code == 200 then data._ff = math.max(1, ff - 1)
    elseif code == 208 then data._ff = math.min(#fields, ff + 1)
    elseif code == 203 then data._fs = fs - 1; if data._fs < 1 then data._fs = #secs end; data._ff = 1
    elseif code == 205 then data._fs = fs + 1; if data._fs > #secs then data._fs = 1 end; data._ff = 1
    elseif code == 15 then
      data._ff = ff + 1; if data._ff > #fields then data._ff = 1; data._fs = fs + 1; if data._fs > #secs then data._fs = 1 end end
    elseif code == 28 then
      local f = fields[ff]; if not f then return end
      if f.t == "b" then f.v = not f.v
      elseif f.t == "e" and f.c then
        local cur = tostring(f.v or f.c[1])
        for ci, cv in ipairs(f.c) do if cv == cur then f.v = f.c[(ci % #f.c) + 1]; break end end
      else data._eb = tostring(f.v or ""); data._editing = true; data._status = nil end
    elseif code >= 3 and code <= 9 then data._fs = code - 1; data._ff = 1 end  -- keys 2-8 = sections 1-7
  else
    local f = fields[ff]
    if code == 28 then
      if f then
        if f.t == "n" then local n = tonumber(data._eb); if n then f.v = n; data._status = f.l.."="..n else data._status = "Invalid number" end
        else f.v = data._eb; data._status = f.l.." updated" end
      end; data._editing = false; data._eb = ""
    else
      if char and char >= 32 and char <= 126 then
        local ch = string.char(char)
        if f and f.t == "n" then if (ch>="0" and ch<="9") or ch=="." or (ch=="-" and #data._eb==0) then data._eb = data._eb..ch end
        else data._eb = data._eb..ch end
      end
    end
  end
end

-----------------------------------------------------------------------
-- Constructor
-----------------------------------------------------------------------
function BrokerUI.new(rob, config, deps)
  deps = deps or {}
  local self = setmetatable({}, BrokerUI)
  self._rob = rob; self._config = config or {}
  self._gpu = deps.gpu; self._screen_addr = deps.screen_addr
  self._now = deps.now_fn or os.clock; self._log = deps.log or print
  self._pump_fn = deps.pump_fn
  self._current_page = "dashboard"
  self._dispatch_log = {}; self._prev_lane_states = {}
  self._running = false; self._start_time = self._now()
  self._broker_ctx = deps.broker_ctx; self._broker_bm = deps.broker_bm
  self._broker_active = false; self._status = "Press S to start broker"
  self._pages = {
    dashboard = { render = render_dashboard, handle_key = handle_dashboard_key },
    logs      = { render = render_logs,      handle_key = handle_logs_key },
    config    = { render = render_config,    handle_key = handle_config_key },
  }
  return self
end

-----------------------------------------------------------------------
-- Broker start/stop
-----------------------------------------------------------------------
function BrokerUI:_start_broker()
  if self._broker_active then self._status = "Broker already running"; return end
  local ctx = self._broker_ctx
  if not ctx then
    -- Try to build broker context on-demand
    self._status = "Building broker..."
    local ok, bm = pcall(require, "broker_main")
    if ok and bm then
      local okb, result = pcall(bm.build, bm)
      if okb and result then
        ctx = result; self._broker_ctx = ctx; self._broker_bm = bm
        self._rob = ctx.rob; self._config = ctx.config
        -- Build basic pump
        local poll, rob, st = ctx.poll, ctx.rob, ctx.state
        self._pump_fn = function()
          local okr, results = pcall(poll.poll_all, poll)
          if okr and results then for mid, r in pairs(results) do st.poll_results[mid] = r end end
          pcall(rob.tick, rob, st.poll_results)
        end
        self._status = "Broker built — starting..."
      else self._status = "Build failed: "..tostring(result or okb); return end
    else self._status = "broker_main not available"; return end
  end
  self._log("[Broker] starting lane workers...")
  local ok, err = pcall(function()
    if self._broker_bm and self._broker_bm.attach_tasks then self._broker_bm.attach_tasks(ctx) end
    if ctx.scheduler and ctx.poll and ctx.rob then
      local sched, poll, rob, st = ctx.scheduler, ctx.poll, ctx.rob, ctx.state
      self._pump_fn = function()
        pcall(function()
          if sched then for _ = 1, 5 do pcall(sched.step, sched) end end
          local okr, results = pcall(poll.poll_all, poll)
          if okr and results then for mid, r in pairs(results) do st.poll_results[mid] = r end end
          pcall(rob.tick, rob, st.poll_results)
        end)
      end
    end
  end)
  if not ok then self._log("[Broker] start FAILED: "..tostring(err)); self._status = "Start FAILED: "..tostring(err); return end
  self._broker_active = true; self._status = "Broker RUNNING"
  self._log("[Broker] RUNNING — press Q to stop")
end

function BrokerUI:_stop_broker()
  if not self._broker_active then return end
  self._log("[Broker] stopping...")
  local ctx = self._broker_ctx
  if ctx and ctx.scheduler then pcall(ctx.scheduler.clear, ctx.scheduler) end
  self._broker_active = false
  if ctx then
    local poll, rob, st = ctx.poll, ctx.rob, ctx.state
    self._pump_fn = function()
      local ok, results = pcall(poll.poll_all, poll)
      if ok and results then for mid, r in pairs(results) do st.poll_results[mid] = r end end
      pcall(rob.tick, rob, st.poll_results)
    end
  end
  self._log("[Broker] STOPPED")
end

-----------------------------------------------------------------------
-- Dispatch ring buffer
-----------------------------------------------------------------------
function BrokerUI:_track_dispatch()
  if not self._rob then return end
  local dbg = self._rob:get_debug(); local lanes = dbg.lanes or {}
  for mid, lane in pairs(lanes) do
    local prev = self._prev_lane_states[mid]; local curr = lane.state
    if prev and prev ~= curr then
      local e = { job_id = lane.current_job_id, machine_id = mid, time = self._now() }
      if curr == "WORKING" then e.status = "running"
      elseif curr == "IDLE" then e.status = prev == "WORKING" and "done" or "idle"
      elseif curr == "FAULTED" then e.status = "failed" else e.status = curr end
      self._dispatch_log[#self._dispatch_log + 1] = e
      while #self._dispatch_log > 50 do table.remove(self._dispatch_log, 1) end
    end
    self._prev_lane_states[mid] = curr
  end
end

function BrokerUI:_build_dashboard_data()
  if not self._rob then
    return { lanes={}, pending={}, locks={}, dispatch_log={}, debug={},
      subnet_id=self._config.subnet_id or "?", uptime=self._now()-self._start_time,
      port=self._config.broker_modem_port or self._config.main_net_channel or 0,
      max_lanes=#(self._config.machines or {}), now_fn=self._now, broker_active=self._broker_active, status=self._status }
  end
  local dbg = self._rob:get_debug()
  return { lanes=dbg.lanes, pending=self._rob:pending_queue(),
    locks=self._rob:get_locks(), dispatch_log=self._dispatch_log, debug=dbg,
    subnet_id=self._config.subnet_id or "?", uptime=self._now()-self._start_time,
    port=self._config.broker_modem_port or self._config.main_net_channel or 0,
    max_lanes=#(self._config.machines or {}), now_fn=self._now, broker_active=self._broker_active, status=self._status }
end

-----------------------------------------------------------------------
-- Data refresh
-----------------------------------------------------------------------
function BrokerUI:_refresh_data()
  self:_track_dispatch()
  local page = self._pages[self._current_page]; if not page then return end
  if self._current_page == "dashboard" then
    page.data = self:_build_dashboard_data()
  elseif self._current_page == "logs" then
    local lines = {}; local f = io.open(LOG_PATH, "r")
    if f then for line in f:lines() do lines[#lines+1] = line end; f:close() end
    page.data = { lines = lines, path = LOG_PATH, follow = true, offset = 0 }
  elseif self._current_page == "config" then
    page.data = page.data or { config_path = "/home/subnet_broker/config.lua" }
  end
end

-----------------------------------------------------------------------
-- Navigation
-----------------------------------------------------------------------
function BrokerUI:_nav_to(name)
  if self._pages[name] then self._current_page = name; self:_refresh_data() end
end
function BrokerUI:_nav_next()
  local order = {"dashboard","logs","config"}
  for i, n in ipairs(order) do if n == self._current_page then self:_nav_to(order[i%3+1]); return end end
end

-----------------------------------------------------------------------
-- Key handling (char=ASCII, code=scancode)
-----------------------------------------------------------------------
function BrokerUI:_handle_key(code, char)
  -- If editing a config field, route ALL keys to config handler
  -- (except Q=quit and Ctrl+S=save which are handled globally)
  if self._current_page == "config" then
    local cfg = self._pages.config
    if cfg and cfg.data and cfg.data._editing then
      if code == 16 then self:_stop_broker(); self._running = false; return end    -- Q quits
      if code == 31 and self._kb and self._kb.isControlDown() then                 -- Ctrl+S saves
        cfg.handle_key(code, char, cfg.data); return
      end
      cfg.handle_key(code, char, cfg.data); return                                  -- everything else to config
    end
  end

  -- Global navigation (only when NOT editing)
  if code == 2 then self:_nav_to("dashboard")                               -- 1 key
  elseif code == 3 then self:_nav_to("logs")                                -- 2 key
  elseif code == 4 then self:_nav_to("config")                              -- 3 key
  elseif code == 31 then                                                     -- S key (0x1F)
    if self._current_page == "config" and self._kb and self._kb.isControlDown() then
      local page = self._pages.config
      if page and page.handle_key then page.handle_key(code, char, page.data) end; return
    end
    if self._broker_active then self:_stop_broker() else self:_start_broker() end; return
  elseif code == 16 then self:_stop_broker(); self._running = false; return -- Q key (0x10)
  elseif code == 15 then self:_nav_next()                                   -- Tab
  elseif code == 14 and self._current_page == "config" then                 -- Backspace on config = go back
    self:_nav_to("dashboard"); return
  else
    local page = self._pages[self._current_page]
    if page and page.handle_key then page.handle_key(code, char, page.data) end
  end
end

-----------------------------------------------------------------------
-- Render
-----------------------------------------------------------------------
function BrokerUI:_render()
  local gpu = self._gpu; if not gpu then return end
  local okr, w, h = pcall(gpu.getResolution, gpu)
  if not okr or not w then w, h = 80, 25 end
  if type(w) ~= "number" then w = 80 elseif type(h) ~= "number" then h = 25 end
  w, h = math.max(1, w), math.max(1, h)
  FL(gpu, 1, 1, w, h, " ")
  local page = self._pages[self._current_page]
  if page and page.render then
    local ok, err = pcall(page.render, gpu, w, h - 1, page.data)
    if not ok then self._log("[BrokerUI] render error ("..self._current_page.."): "..tostring(err)) end
  end
end

-----------------------------------------------------------------------
-- Headless fallback
-----------------------------------------------------------------------
function BrokerUI:headless_line()
  self:_track_dispatch()
  if not self._rob then return "[Broker] no data" end
  local dbg = self._rob:get_debug(); local pending = self._rob:pending_count()
  local parts = {"buf="..tostring(dbg.buffer_state), "pend="..tostring(pending), "locks="..tostring(dbg.active_locks or 0)}
  local lp = {}; for mid, l in pairs(dbg.lanes or {}) do lp[#lp+1] = ("%s:%s"):format(tostring(mid):sub(1,6), tostring(l.state)) end
  if #lp > 0 then parts[#parts+1] = table.concat(lp, " ") end
  return "[Broker] "..table.concat(parts, " | ")
end

-----------------------------------------------------------------------
-- Main loop
-----------------------------------------------------------------------
function BrokerUI:run()
  if not self._gpu then
    while true do if self._pump_fn then pcall(self._pump_fn) end; print(self:headless_line()); os.execute("sleep 1") end
  end
  local event = require("event")
  local ok_kb, kb = pcall(require, "keyboard"); self._kb = ok_kb and kb or nil
  if self._screen_addr then pcall(self._gpu.bind, self._screen_addr) end
  local mw, mh = 80, 25
  pcall(function()
    local ok, w, h = pcall(self._gpu.getResolution)
    if ok and w and h then mw, mh = w, h end
  end)
  pcall(self._gpu.setResolution, mw, mh)
  self._running = true; pcall(self._refresh_data, self); pcall(self._render, self)
  while self._running do
    if self._pump_fn then pcall(self._pump_fn) end
    pcall(self._refresh_data, self); pcall(self._render, self)
    local ev = { event.pull(1.0, "key_down") }
    if ev[1] == "key_down" then self._ctrl = self._kb and self._kb.isControlDown(); self:_handle_key(ev[4], ev[3]) end
  end
  FL(self._gpu, 1, 1, mw, mh, " "); FG(self._gpu, W); GS(self._gpu, 1, 1, "AutoOS Broker stopped.")
end

return BrokerUI
