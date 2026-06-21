-- page_config.lua - Config editor page: split-pane section/field editor with edit mode
-- Lua 5.2, OpenComputers. Inherits from BasePage.
-- ponytail: targeted field redraws only — no full re-render on keystrokes; add undo stack if users ask.

local BasePage = require("class_base_page")
local U = require("ui_utils")
local C = require("ui_components")

local ConfigPage = setmetatable({}, {__index = BasePage})
ConfigPage.__index = ConfigPage
ConfigPage.page_id = "config"

local CONFIG_PATH = "/home/subnet_broker/config.lua"

-----------------------------------------------------------------------
-- Serialize config table to string (local helper)
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

-----------------------------------------------------------------------
-- Constructor
-----------------------------------------------------------------------
function ConfigPage.new(deps)
  local o = BasePage.new(deps)
  setmetatable(o, ConfigPage)
  o._sections = nil     -- built once from config file
  o._fs = 1             -- focused section index
  o._ff = 1             -- focused field index
  o._editing = false    -- editing a text field
  o._eb = ""            -- edit buffer
  o._locked = false     -- broker running = locked
  o._status = nil       -- status message
  o._rx = 1             -- right pane x
  o._rw = 40            -- right pane width
  o._machines = nil     -- machine config rows
  o._cfg = nil          -- parsed config table
  return o
end

function ConfigPage:on_unmount()
  self._editing = false
  self._eb = ""
  BasePage.on_unmount(self)  -- chain to parent: clears hitboxes
end

function ConfigPage:is_modal()
  return self._editing
end

function ConfigPage:set_data(t)
  if type(t) ~= "table" then return end
  -- Only merge _locked from router; preserve all other page-local state
  if t._locked ~= nil then
    self._locked = t._locked
  end
  -- Cancel editing if broker started while we were editing
  if self._locked and self._editing then
    self._editing = false
    self._eb = ""
  end
end

-----------------------------------------------------------------------
-- Targeted config field redraw (2 rows: value + description)
-- Called from handle_input for keystroke-level updates without full render.
-----------------------------------------------------------------------
function ConfigPage:redraw_field(field_idx)
  local gpu = self.deps.gpu; if not gpu then return end
  local sections = self._sections; if not sections then return end
  local fs = self._fs or 1
  local sec = sections[fs]
  if not sec or sec.ismach then return end  -- machines section uses full render
  local fields = sec.f or {}
  if field_idx < 1 or field_idx > #fields then return end
  local f = fields[field_idx]; if not f then return end

  local rx = self._rx or 1
  local rw = self._rw or 40
  local locked = self._locked
  local ff = self._ff or 1
  local editing = self._editing
  local h = self._h or 25

  -- Only redraw if field is within the visible viewport
  local max_vis = math.floor((h - 4) / 2)
  if field_idx > max_vis then return end

  local row = 4 + (field_idx - 1) * 2

  -- Value line
  local val
  if editing and not locked and field_idx == ff then
    val = (self._eb or "") .. "_"
  elseif f.t == "b" then
    val = f.v and "true" or "false"
  else
    val = tostring(f.v or "")
  end
  local lb = f.l
  if #lb > 20 then lb = lb:sub(1, 19) .. "." end
  local fc = (field_idx == ff and not locked) and U.CYAN or (locked and 0x404040 or U.W)
  U.FG(gpu, fc)
  U.GS(gpu, rx, row, U.pad((" %-21s %s"):format(lb, val), rw))

  -- Description line (always draw to clear stale text)
  U.FG(gpu, 0x404040)
  if f.d then
    U.GS(gpu, rx, row + 1, U.pad(("   %s"):format(f.d:sub(1, rw - 4)), rw))
  else
    U.GS(gpu, rx, row + 1, string.rep(" ", rw))
  end
end

-----------------------------------------------------------------------
-- Key handling
-----------------------------------------------------------------------
function ConfigPage:handle_input(event)
  local code, char = event.code, event.char
  local sections = self._sections; if not sections or #sections == 0 then return false end
  local secs = sections
  local fs = self._fs or 1; if fs < 1 then fs = 1 elseif fs > #secs then fs = #secs end
  self._fs = fs
  local sec = secs[fs] or {}; local fields = sec.f or {}
  local ff = self._ff or 1
  if ff < 1 then ff = 1 elseif ff > #fields then ff = #fields end
  self._ff = ff

  -- Ctrl+S: save config (router pre-checks Ctrl+S before calling here)
  if code == 31 then
    if self._editing then self._editing = false; self._eb = "" end
    local out = self._cfg or {}
    for _, s in ipairs(self._sections or {}) do
      for _, f in ipairs(s.f or {}) do
        if f.k then out[f.k] = f.v end
      end
    end
    out.machines = self._machines
    local content = serialize_config(out)
    local fh, err = io.open(CONFIG_PATH, "w")
    if fh then fh:write(content); fh:close(); self._status = "Saved OK -- reboot to apply"
    else self._status = "Error: " .. tostring(err) end
    return true
  end

  -- Backspace in editing mode: delete last char
  if code == 14 and self._editing then
    self._eb = self._eb:sub(1, -2)
    return true
  end

  if not self._editing then
    -- Navigation (not editing)
    if code == 200 then
      self._ff = math.max(1, ff - 1)
    elseif code == 208 then
      self._ff = math.min(#fields, ff + 1)
    elseif code == 203 then
      self._fs = fs - 1; if self._fs < 1 then self._fs = #secs end; self._ff = 1
    elseif code == 205 then
      self._fs = fs + 1; if self._fs > #secs then self._fs = 1 end; self._ff = 1
    elseif code == 15 then  -- Tab
      self._ff = ff + 1
      if self._ff > #fields then self._ff = 1; self._fs = fs + 1; if self._fs > #secs then self._fs = 1 end end
    elseif code == 28 then  -- Enter: toggle/edit
      if self._locked then return true end  -- blocked: stop broker first
      local f = fields[ff]; if not f then return true end
      if f.t == "b" then
        f.v = not f.v
      elseif f.t == "e" and f.c then
        local cur = tostring(f.v or f.c[1])
        for ci, cv in ipairs(f.c) do if cv == cur then f.v = f.c[(ci % #f.c) + 1]; break end end
      else
        self._eb = tostring(f.v or ""); self._editing = true; self._status = nil
      end
    elseif code >= 3 and code <= 9 then  -- keys 2-8 = jump to sections 1-7
      self._fs = code - 1; self._ff = 1
    else
      return false
    end
  else
    -- Editing mode: character entry or Enter to commit
    local f = fields[ff]
    if code == 28 then  -- Enter: commit edit
      if f then
        if f.t == "n" then
          local n = tonumber(self._eb); if n then f.v = n; self._status = f.l.."="..n else self._status = "Invalid number" end
        else
          f.v = self._eb; self._status = f.l.." updated"
        end
      end
      self._editing = false; self._eb = ""
    else
      if char and char >= 32 and char <= 126 then
        local ch = string.char(char)
        if f and f.t == "n" then
          if (ch>="0" and ch<="9") or ch=="." or (ch=="-" and #self._eb==0) then
            self._eb = self._eb..ch
          end
        else
          self._eb = self._eb..ch
        end
      else
        return false
      end
    end
  end
  return true
end

-----------------------------------------------------------------------
-- Render
-----------------------------------------------------------------------
function ConfigPage:render()
  local gpu = self.deps.gpu; if not gpu then return end
  local w, h = self._w, self._h

  -- Build sections once (from config file)
  if not self._sections or #self._sections == 0 then
    local cfg = {}
    if not self._cfg then
      local ok, c = pcall(dofile, CONFIG_PATH)
      if ok and type(c) == "table" then self._cfg = c; cfg = c end
    else cfg = self._cfg end
    local sc, ct = cfg.scheduler or {}, cfg.central or {}
    self._sections = {
      {n="Network", f={
        {l="Subnet ID",       v=cfg.subnet_id or "",               t="s", d="Unique name for this subnet (e.g. 'lv_crafting')"},
        {l="Modem Port",       v=cfg.broker_modem_port or 106,      t="n", min=1, max=65535, d="Port this broker listens on for modem messages"},
        {l="Main Channel",     v=cfg.main_net_channel or 105,       t="n", min=1, max=65535, d="Orchestrator network channel for craft requests"},
        {l="Orch Addr",        v=cfg.orchestrator_address or "",    t="s", d="UUID of the orchestrator computer's modem"},
      }},
      {n="Mode & Timing", f={
        {l="Input Mode",        v=cfg.input_mode or "central",      t="e", c={"per_lane","central"}, d="per_lane=AE imports to each machine, central=buffer first"},
        {l="Completion Mode",   v=cfg.completion_mode or "both",    t="e", c={"both","adapter","drain"}, d="How to detect job completion: adapter, drain bus, or both"},
        {l="Round Robin",       v=cfg.do_round_robin~=false,        t="b", d="Distribute jobs evenly across all lanes"},
        {l="Tick Interval (s)",  v=cfg.tick_interval or 1.0,        t="n", min=0.01, d="Seconds between dispatch checks (lower = faster, higher = less CPU)"},
        {l="Settle (s)",        v=cfg.settle_s or 0.1,              t="n", min=0, d="Delay after stocking before checking delivery"},
        {l="Monitor Poll (s)",  v=cfg.monitor_poll_s or 0.15,       t="n", min=0.01, d="How often to repoll machines during active jobs"},
        {l="Staging Timeout",   v=cfg.staging_timeout_s or 60,      t="n", min=0, d="Max seconds to wait for AE2 to deliver items to interface"},
        {l="Completion TO",     v=cfg.completion_timeout_s or 300,  t="n", min=0, d="Max seconds to wait for machine to finish crafting"},
        {l="Req Empty Return",  v=cfg.require_empty_return~=false,  t="b", d="Require return bus to be empty before starting next job"},
      }},
      {n="AE2 & Database", f={
        {l="DB Address",        v=cfg.database_address or "",       t="s", d="UUID of the ME Database (storage bus) address"},
        {l="DB Slot Count",     v=cfg.database_slot_count or 9,     t="n", min=1, d="Number of slots in the database (usually 9)"},
        {l="IF Item Slots",     v=cfg.interface_item_slots or 9,    t="n", min=1, d="Number of config slots on the dual ME interface"},
        {l="IF Slot Start",     v=cfg.interface_item_slot_start or 1,t="n", min=1, d="First config slot index on the interface (usually 1)"},
        {l="IF Fluid Side",     v=cfg.interface_fluid_side or 0,    t="n", min=0, max=5, d="Side of interface for fluid transfer (0=none, 1-6=sides)"},
        {l="Shared IF Addr",    v=cfg.shared_interface_address or "",t="s", d="UUID of shared ME interface (if not per-machine)"},
        {l="Chest Slot Start",  v=cfg.chest_slot_start or 1,        t="n", min=1, d="First slot in the central buffer chest to use"},
        {l="Circuit Bus Slot",  v=cfg.circuit_bus_slot or 1,        t="n", min=1, d="Slot on the input bus reserved for the circuit"},
        {l="Circuit Item",      v=cfg.circuit_item_name or "gregtech:gt.integrated_circuit", t="s", d="Item name of the circuit to keep in the bus"},
      }},
      {n="Redstone Lock", f={
        {l="RS Address",        v=cfg.redstone_address or "",       t="s", d="UUID of redstone I/O block for machine locking"},
        {l="RS Side",           v=cfg.redstone_side or 0,           t="n", min=0, max=5, d="Side of redstone block to pulse (0=none, 1-6=sides)"},
        {l="Pulse Duration",    v=cfg.redstone_pulse_s or 0.5,      t="n", min=0, d="Seconds to hold the redstone pulse"},
      }},
      {n="Scheduler", f={
        {l="Max Parallel",      v=sc.max_parallel_lanes,            t="n", min=1, nilok=true, d="Max lanes that can run jobs simultaneously (nil=unlimited)"},
        {l="Max Job Attempts",  v=sc.max_job_attempts or 2,         t="n", min=1, d="Retry count for failed jobs before marking lane FAULTED"},
        {l="Watchdog Grace",    v=sc.watchdog_grace_s or 10,        t="n", min=0, d="Seconds before watchdog declares a stuck lane as FAULTED"},
        {l="Persist Jobs",      v=sc.persist_jobs or "startup_sweep", t="e", c={"startup_sweep","file"}, d="How to persist pending jobs across reboots"},
        {l="Lane Budget",       v=sc.active_lane_budget or 32,      t="n", min=1, d="Max coroutines to allocate for lane workers"},
      }},
      {n="Central Buffer", f={
        {l="Monitor Mode",      v=ct.monitor or "inventory_controller", t="e", c={"inventory_controller","adapter"}, d="Use inventory controller or adapter to watch central buffer"},
        {l="IC Side",           v=ct.inventory_controller_side or 0, t="n", min=0, max=5, d="Side of the inventory controller to read"},
        {l="Buffer Adapter",    v=ct.buffer_adapter_address or "",   t="s", d="UUID of adapter on the central buffer chest"},
        {l="Buffer Side",       v=ct.buffer_adapter_side or 0,       t="n", min=0, max=5, d="Side of the buffer chest to read from"},
        {l="Fluid Adapter",     v=ct.fluid_adapter_address or "",    t="s", d="UUID of adapter on the central fluid buffer"},
        {l="Fluid Side",        v=ct.fluid_adapter_side or 0,        t="n", min=0, max=5, d="Side of the fluid buffer to read from"},
        {l="Chest Slot Start",  v=ct.chest_slot_start or 1,          t="n", min=1, d="First slot in the central buffer to scan"},
        {l="Max Circuits",      v=ct.max_circuits_in_buffer or 1,    t="n", min=1, d="Max circuits allowed in the buffer for job matching"},
        {l="Ingest Mode",       v=ct.ingest_mode or "event_or_poll", t="e", c={"event_or_poll","event","poll"}, d="How to detect new items: event-driven, polling, or both"},
        {l="Job Stabilize",     v=ct.job_stabilize_s or 1.0,        t="n", min=0, d="Seconds to wait for AE crafting to settle before scanning"},
        {l="Stabilize",         v=ct.stabilize_s or 1.0,             t="n", min=0, d="Seconds to wait for buffer inventory to stabilize"},
        {l="Settle",            v=ct.settle_s or 0.0,                t="n", min=0, d="Extra settle time after buffer changes before dispatch"},
        {l="IF Wait",           v=ct.interface_wait_s or 5.0,        t="n", min=0, d="Max seconds to wait for interface to accept config changes"},
        {l="Req IF Staging",    v=ct.require_interface_staging or false, t="b", d="Require interface slots to be staged before job starts"},
      }},
      {n="Machines", ismach=true, f={
        {l="ID",                t="s"}, {l="GT Address", t="s"}, {l="IF Address", t="s"},
        {l="Item TP Addr",      t="s"}, {l="Fluid TP Addr", t="s"},
        {l="Side Buffer",       t="n", min=0, max=5}, {l="Side Bus B", t="n", min=0, max=5},
        {l="Side Return",       t="n", min=0, max=5}, {l="Side Fluid Buffer", t="n", min=0, max=5},
        {l="Side Fluid Hatch",  t="n", min=0, max=5}, {l="Input Slot", t="n", min=1},
      }},
    }
    if not self._machines then self._machines = cfg.machines or {} end
  end

  local sections = self._sections
  if not sections or #sections == 0 then U.FG(gpu,U.R);U.GS(gpu,2,2,"Config unavailable");return end
  local fs = self._fs or 1
  if fs < 1 then fs = 1 elseif fs > #sections then fs = #sections end
  self._fs = fs
  local sec = sections[fs] or sections[1]
  if not sec then U.FG(gpu,U.R);U.GS(gpu,2,2,"Config section error");return end
  local fields = sec.f or {}
  local ff = self._ff or 1
  if ff < 1 then ff = 1 elseif ff > #fields then ff = #fields end
  self._ff = ff

  -- Header
  U.FG(gpu, U.GRAY)
  U.GS(gpu, 1, 1, U.pad((" Config: subnet_broker/config.lua  [Ctrl+S:Save]"):sub(1, w), w))

  -- Left pane: sections
  local lw = math.floor(w * 0.35); if lw < 10 then lw = 10 end
  for i, s in ipairs(sections) do
    if i > h - 3 then break end
    U.FG(gpu, i == fs and U.W or U.GRAY)
    U.GS(gpu, 1, i + 1, U.pad((" %d.%s"):format(i, s.n), lw))
  end

  -- Right pane: fields (2-line layout: value + description)
  local rx, rw = lw + 2, w - lw - 1
  self._rx = rx; self._rw = rw  -- stash for targeted keystroke redraws
  local locked = self._locked
  U.FG(gpu, U.Y)
  U.GS(gpu, rx, 2, U.pad(sec.n, rw))
  if locked then
    U.FG(gpu, U.R)
    U.GS(gpu, rx, 3, U.pad(" *** STOP BROKER TO EDIT CONFIG ***", rw))
  else
    U.FG(gpu, U.GRAY)
    U.GS(gpu, rx, 3, string.rep("-", rw))
  end
  local row = 4
  local max_vis = math.floor((h - row) / 2)  -- each field = 2 lines
  for i = 1, math.min(#fields, max_vis) do
    if row > h - 3 then break end
    local f = fields[i]
    local val = (self._editing and not locked and i == ff) and (self._eb or "").."_" or tostring(f.v or "")
    if f.t == "b" and not (self._editing and not locked) then val = f.v and "true" or "false" end
    local lb = f.l; if #lb > 20 then lb = lb:sub(1,19).."." end
    local fc = (i == ff and not locked) and U.CYAN or (locked and 0x404040 or U.W)
    U.FG(gpu, fc)
    U.GS(gpu, rx, row, U.pad((" %-21s %s"):format(lb, val), rw))
    -- Description line
    U.FG(gpu, 0x404040)
    if f.d then
      U.GS(gpu, rx, row + 1, U.pad(("   %s"):format(f.d:sub(1, rw - 4)), rw))
    else
      U.GS(gpu, rx, row + 1, string.rep(" ", rw))
    end
    row = row + 2
  end

  -- Machines section
  if sec.ismach then
    U.FG(gpu, U.GRAY)
    U.GS(gpu, rx, row, U.pad((" Machines: %d"):format(#self._machines), rw))
    row = row + 1
    for i = 1, math.min(#self._machines, h - row) do
      local m = self._machines[i]
      U.FG(gpu, i == ff and U.CYAN or (locked and 0x404040 or U.W))
      U.GS(gpu, rx, row, U.pad((" %d. %s"):format(i, m.id or ("#"..i)), rw))
      row = row + 1
    end
  end

  -- Blank stale right-pane rows
  U.FG(gpu, U.GRAY)
  for cr = row, h - 2 do
    U.GS(gpu, 1, cr, string.rep(" ", w))
  end

  -- Status + help
  if self._status then
    U.FG(gpu, self._status:find("Err") and U.R or U.G)
    U.GS(gpu, 1, h - 1, U.pad(self._status:sub(1, w), w))
  end
  U.FG(gpu, 0x404040)
  local help_text = (locked and "LOCKED: stop broker first  Q:quit"
    or self._editing and "EDIT: Enter=commit Bksp=delete  Ctrl+V=paste"
    or "Up/Dn:field L/R:section Tab:next Enter:edit Ctrl+S:save 2-8:jump")
  U.GS(gpu, 1, h, U.pad(help_text, w))
end

return ConfigPage
