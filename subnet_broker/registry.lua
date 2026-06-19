--[[
  AutoOS — Static Hardware Registry (MMU Phase 1)

  Boot-time discovery: scans the OC network, caches every me_interface and
  transposer proxy, pre-reads the physical database, and builds pre-resolved
  machine entries.  The returned table is READ-ONLY — no runtime writes.

  Cache keys follow descriptor_cache.lua conventions:
    item  → "item:<name>:<damage>:<label>"
    fluid → "fluid:<fluid_label>"
]]

local HW = require("hw")

local Registry = {}

-- ---------------------------------------------------------------------------
-- cache-key helpers (must match descriptor_cache.lua format)
-- ---------------------------------------------------------------------------

local function item_cache_key(name, damage, label)
  return "item:" .. tostring(name) .. ":" .. tostring(damage or 0) .. ":" .. tostring(label or "")
end

local function fluid_cache_key(fluid_label)
  return "fluid:" .. tostring(fluid_label)
end

-- ---------------------------------------------------------------------------
-- build-phase helpers (private, not exported)
-- ---------------------------------------------------------------------------

--- Eagerly proxy every me_interface / transposer visible on the network.
local function cache_all_proxies(component, list)
  for addr, ctype in pairs(list) do
    if ctype == "me_interface" or ctype == "transposer" then
      HW.proxy(component, addr, ctype) -- ctype is the correct hint
    end
  end
end

--- Validate every configured address is reachable.  Returns (true) or (nil, err).
local function validate_components(component, config)
  local central = config.central or {}
  local adapters = {
    { central.fluid_adapter_address, "central fluid adapter", "transposer" },
    { central.buffer_adapter_address, "central buffer adapter", "transposer" },
  }
  for _, a in ipairs(adapters) do
    if a[1] and a[1] ~= "" then
      local _, err = HW.require_proxy(component, a[2], a[1], a[3])
      if err then return nil, err end
    end
  end

  if config.shared_interface_address and config.shared_interface_address ~= "" then
    local _, err = HW.require_proxy(component, "shared me_interface",
      config.shared_interface_address, "me_interface")
    if err then return nil, err end
  end

  for _, m in ipairs(config.machines) do
    local required = {
      { m.gt_address,               "gt_address",               "transposer" },
      { m.item_transposer_address,  "item_transposer_address",  "transposer" },
      { m.fluid_transposer_address, "fluid_transposer_address", "transposer" },
    }
    for _, r in ipairs(required) do
      if r[1] and r[1] ~= "" then
        local _, err = HW.require_proxy(component, r[2] .. " (" .. m.id .. ")", r[1], r[3])
        if err then return nil, err end
      end
    end
    if m.interface_address and m.interface_address ~= "" then
      local _, err = HW.require_proxy(component,
        "me_interface (" .. m.id .. ")", m.interface_address, "me_interface")
      if err then return nil, err end
    end
  end

  return true
end

--- Read all database slots, building item and fluid reverse-lookup maps.
--- Returns (item_map, fluid_map) or (nil, nil, err).
local function build_db_maps(component, config)
  local db_addr = config.database_address
  if not db_addr or db_addr == "" or db_addr:find("SET_", 1, true) then
    return {}, {}
  end

  local db, err = HW.require_proxy(component, "database", db_addr, "database")
  if not db then return nil, nil, err end

  local item_map, fluid_map = {}, {}
  local slot_count = config.database_slot_count or 9

  for slot = 1, slot_count do
    local ok, entry = pcall(db.get, slot)
    if ok and type(entry) == "table" and entry.name then
      if entry.name:lower():find("fluid_drop", 1, true) then
        -- fluid drop: extract clean fluid name from label
        local label = entry.label or ""
        local fluid_name = label
        if label:sub(1, 8):lower() == "drop of " then
          fluid_name = label:sub(9)
        end
        local info = { address = db_addr, slot = slot }
        fluid_map[fluid_cache_key(fluid_name)] = info
        if fluid_name ~= label then
          fluid_map[fluid_cache_key(label)] = info
        end
      else
        -- regular item / circuit
        local key = item_cache_key(entry.name, entry.damage, entry.label)
        item_map[key] = { address = db_addr, slot = slot }
      end
    end
  end

  return item_map, fluid_map
end

--- Build pre-resolved machine entries from config + proxy cache.
local function build_machines(component, config)
  local machines = {}
  local shared_iface = config.shared_interface_address
  local has_shared = shared_iface ~= nil and shared_iface ~= ""

  for _, m in ipairs(config.machines) do
    local iface_addr = m.interface_address
    if (not iface_addr or iface_addr == "") and has_shared then
      iface_addr = shared_iface
    end

    local entry = {
      id              = m.id,
      gt_proxy        = HW.proxy(component, m.gt_address),
      item_tp         = HW.proxy(component, m.item_transposer_address),
      fluid_tp        = HW.proxy(component, m.fluid_transposer_address),
      iface           = iface_addr and HW.proxy(component, iface_addr) or nil,
      side_buffer     = m.side_buffer,
      side_bus_b      = m.side_bus_b,
      side_return     = m.side_return,
      side_fluid_buffer = m.side_fluid_buffer,
      side_fluid_hatch  = m.side_fluid_hatch,
      input_slot      = m.input_slot,
    }

    -- copy any additional per-machine fields used by lane dispatch
    for _, f in ipairs({ "interface_fluid_side", "buffer_adapter_side",
                         "interface_item_slots", "interface_item_slot_start",
                         "buffer_adapter_address", "fluid_adapter_address" }) do
      if m[f] ~= nil then entry[f] = m[f] end
    end

    machines[m.id] = entry
  end

  return machines
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build the static registry.  Call ONCE at boot.
---@param config  table  validated Config table
---@param component table  OC component API (require("component"))
---@return table|nil registry
---@return string|nil err
function Registry.build(config, component)
  if not component or not component.list then
    return nil, "component API unavailable"
  end

  local Config = require("config")
  local ok, err = Config.validate(config)
  if not ok then
    return nil, "config invalid: " .. tostring(err)
  end

  local list = component.list()

  -- 1. Cache every me_interface / transposer on the network
  cache_all_proxies(component, list)

  -- 2. Validate required addresses are reachable
  ok, err = validate_components(component, config)
  if not ok then return nil, err end

  -- 3. Read the physical database → reverse maps
  local item_map, fluid_map, db_err = build_db_maps(component, config)
  if db_err then return nil, db_err end

  -- 4. Pre-resolve machine entries
  local machines = build_machines(component, config)
  local machines_list = {}
  for _, m in ipairs(config.machines) do
    machines_list[#machines_list + 1] = m
  end

  -- Cache central adapters as direct fields (rob_dispatcher reads them)
  local c = config.central or {}
  local central_item_adapter, central_item_side
  if (c.monitor or "adapter") == "inventory_controller" then
    local ic = component.inventory_controller
    central_item_adapter = ic or nil
    central_item_side = c.inventory_controller_side or 0
  else
    central_item_adapter = c.buffer_adapter_address and HW.proxy(component, c.buffer_adapter_address, "adapter")
    central_item_side = c.buffer_adapter_side or 0
  end
  local central_fluid_adapter = c.fluid_adapter_address
    and HW.proxy(component, c.fluid_adapter_address, "adapter") or nil
  local central_fluid_side = c.fluid_adapter_side or 0

  local self = {
    _component = component,
    _config    = config,
    _item_db   = item_map,
    _fluid_db  = fluid_map,
    _machines  = machines,
    _poll_results = {},
    _circuit_manager = nil,
    _now = nil,
    _log = nil,

    -- Direct fields for rob_dispatcher (avoid method-call overhead)
    machines = machines_list,
    chest_slot_start = config.chest_slot_start or 1,
    central_item_adapter = central_item_adapter,
    central_item_side = central_item_side,
    central_fluid_adapter = central_fluid_adapter,
    central_fluid_side = central_fluid_side,
  }

  bind_methods(self)
  return self
end

--- Build method closures bound to a specific instance (no self/metatable dependency).
local function bind_methods(inst)
  inst.lookup_db = function(item_name, damage, label)
    return inst._item_db[item_cache_key(item_name, damage, label)]
  end
  inst.lookup_fluid_db = function(fluid_label)
    return inst._fluid_db[fluid_cache_key(fluid_label)]
  end
  inst.get_machine = function(machine_id)
    return inst._machines[machine_id]
  end
  inst.get_iface = function(address)
    if not address then return nil end
    return HW.proxy(inst._component, address, "me_interface")
  end
  inst.get_interface = inst.get_iface
  inst.get_transposer = function(address)
    if not address then return nil end
    return HW.proxy(inst._component, address, "transposer")
  end
  inst.get_config = function()
    return inst._config
  end
  inst.get_now = function()
    return inst._now or function() return 0 end
  end
  inst.get_circuit_manager = function()
    return inst._circuit_manager
  end
  inst.get_poll_result = function(machine_id)
    return inst._poll_results[machine_id]
  end
  inst.seed = function(now_fn, log_fn, circuit_mgr)
    inst._now = now_fn
    inst._log = log_fn
    inst._circuit_manager = circuit_mgr
  end
  return inst
end

return { build = Registry.build, bind_methods = bind_methods }
