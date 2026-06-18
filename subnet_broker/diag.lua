--[[

  AutoOS Subnet Broker — dispatch diagnostic



  Run: loadfile("/home/subnet_broker/diag.lua")()

]]



local sep = package.config:sub(1, 1)

local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"

package.path = here .. sep .. "?.lua;" .. package.path



local Config = require("config")

local LaneSides = require("lane_sides")

local MachinePoll = require("machine_poll")

local LaneDispatch = require("lane_dispatch")

local CircuitManager = require("circuit_manager")
local DescriptorCache = require("descriptor_cache")

local CentralDispatch = require("central_dispatch")



local ok_cfg, cfg_err = Config.validate(Config)

if ok_cfg then

  print("[AutoOS] Config validate: OK (input_mode=" .. tostring(Config.input_mode) .. ")")

else

  print("[AutoOS] Config validate FAILED: " .. tostring(cfg_err))

  return

end



local ok_component, component = pcall(require, "component")

if not ok_component or not component then

  print("[AutoOS] component API unavailable (desktop mode)")

  return

end



local addrs = {}

for addr, ctype in component.list() do addrs[addr] = ctype end



local function status_for(addr)

  if not addr or addr == "" then return "N/A" end

  local ctype = addrs[addr]

  if ctype then return "FOUND " .. ctype end

  return "MISSING"

end



if Config.input_mode == "central" and Config.central then

  local c = Config.central

  print(string.format("[AutoOS] CENTRAL item_adapter=%s %s side=%s",

    tostring(c.buffer_adapter_address), status_for(c.buffer_adapter_address),

    tostring(c.buffer_adapter_side)))

  if c.fluid_adapter_address and c.fluid_adapter_address ~= "" then

    print(string.format("[AutoOS] CENTRAL fluid_adapter=%s %s (optional diag)",

      c.fluid_adapter_address, status_for(c.fluid_adapter_address)))

  else

    print("[AutoOS] CENTRAL fluid_adapter: (none — optional)")

  end

  print(string.format("[AutoOS] CENTRAL stabilize_s=%s max_circuits=%s",

    tostring(c.stabilize_s or 3.0), tostring(c.max_circuits_in_buffer or "off")))

end

if Config.database_address and Config.database_address ~= "" then
  print(string.format("[AutoOS] database=%s %s slots=%s",
    tostring(Config.database_address),
    status_for(Config.database_address),
    tostring(Config.database_slot_count or 25)))
  local db = component.proxy(Config.database_address)
  if db and db.get then
    local used, total = 0, (Config.database_slot_count or 25)
    for slot = 1, total do
      local ok, entry = pcall(db.get, slot)
      if ok and type(entry) == "table" then used = used + 1 end
    end
    print(string.format("[AutoOS] database occupancy: %d/%d", used, total))
    local dump = DescriptorCache.new({ config = Config, component = component }):debug_dump()
    local n = 0
    for _ in pairs(dump) do n = n + 1 end
    print(string.format("[AutoOS] descriptor_cache entries: %d (fresh session expected 0)", n))
  end
else
  print("[AutoOS] database: (not configured)")
end



for _, m in ipairs(Config.machines) do

  print(string.format("[AutoOS] %s gt=%s %s", m.id, m.gt_address, status_for(m.gt_address)))

  print(string.format("[AutoOS] %s item_tp=%s %s", m.id,

    LaneSides.item_transposer_address(m), status_for(LaneSides.item_transposer_address(m))))

  print(string.format("[AutoOS] %s fluid_tp=%s %s", m.id,
    LaneSides.fluid_transposer_address(m), status_for(LaneSides.fluid_transposer_address(m))))

  if m.interface_address and m.interface_address ~= "" then
    print(string.format("[AutoOS] %s iface=%s %s",
      m.id, tostring(m.interface_address), status_for(m.interface_address)))
  else
    print(string.format("[AutoOS] %s iface=(not configured)", m.id))
  end

  if Config.input_mode == "central" then

    print(string.format("[AutoOS] %s iface sides buffer=%s fluid_buffer=%s bus=%s hatch=%s return=%s",

      m.id, tostring(m.side_buffer), tostring(LaneSides.fluid_buffer_side(m)),

      tostring(m.side_bus_b), tostring(m.side_fluid_hatch), tostring(m.side_return or m.side_buffer)))

  else

    print(string.format("[AutoOS] %s item sides buffer=%s bus=%s return=%s",

      m.id, tostring(m.side_buffer), tostring(m.side_bus_b), tostring(m.side_return or m.side_buffer)))

    print(string.format("[AutoOS] %s fluid sides buffer=%s hatch=%s",

      m.id, tostring(LaneSides.fluid_buffer_side(m)), tostring(LaneSides.fluid_hatch_side(m))))

    if m.buffer_adapter_address and m.buffer_adapter_address ~= "" then

      print(string.format("[AutoOS] %s buffer_adapter=%s %s", m.id, m.buffer_adapter_address, status_for(m.buffer_adapter_address)))

    end

  end

end



local poll = MachinePoll.new({ config = Config, component = component })

local results = poll:poll_all()

local healthy = 0

for _, m in ipairs(Config.machines) do

  local st = results[m.id]

  if not st or not st.available then

    print(string.format("[AutoOS] %s poll=UNAVAILABLE (%s)", m.id,

      tostring(st and st.fault_message or "no gt_machine proxy")))

  elseif st.healthy then

    healthy = healthy + 1

    print(string.format("[AutoOS] %s poll=OK active=%s has_work=%s",

      m.id, tostring(st.active), tostring(st.has_work)))

  else

    print(string.format("[AutoOS] %s poll=FAULT %s", m.id, tostring(st.fault_message)))

  end

end



if Config.input_mode == "central" then

  local circuit_manager = CircuitManager.new({ config = Config, component = component })

  local lane_dispatch = LaneDispatch.new({

    config = Config, component = component, circuit_manager = circuit_manager,

    now = function() return 0 end, log = function() end,

  })

  local central = CentralDispatch.new({

    config = Config, component = component, circuit_manager = circuit_manager,

    lane_dispatch = lane_dispatch, now = function() return 0 end, log = function() end,

  })

  local next_m = central:find_available_machine_rr(Config.machines, results, lane_dispatch)

  if next_m then

    print(string.format("[AutoOS] RR next available: %s (rr_index=%s)",

      next_m.id, tostring(central:get_debug().rr_index)))

  else

    print("[AutoOS] RR next available: none (CENTRAL_WAIT_OUTPUT)")

  end

  local cd = central:get_debug()

  print(string.format("[AutoOS] central FSM state=%s bound=%s stable_for=%.1fs",

    cd.state, tostring(cd.bound_machine or "none"), cd.stable_for or 0))

end



if healthy == 0 then

  print("[AutoOS] DIAG: FAIL (no healthy lanes)")

else

  print(string.format("[AutoOS] DIAG: PASS (%d healthy lane(s))", healthy))

end

