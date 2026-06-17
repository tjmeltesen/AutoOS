--[[
  AutoOS Subnet Broker — LCR dispatch diagnostic

  Run: loadfile("/home/subnet_broker/diag.lua")()
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("config")
local LaneSides = require("lane_sides")
local MachinePoll = require("machine_poll")

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
  local ctype = addrs[addr]
  if ctype then return "FOUND " .. ctype end
  return "MISSING"
end

for _, m in ipairs(Config.machines) do
  print(string.format("[AutoOS] %s gt=%s %s", m.id, m.gt_address, status_for(m.gt_address)))
  print(string.format("[AutoOS] %s item_tp=%s %s", m.id,
    LaneSides.item_transposer_address(m), status_for(LaneSides.item_transposer_address(m))))
  print(string.format("[AutoOS] %s fluid_tp=%s %s", m.id,
    LaneSides.fluid_transposer_address(m), status_for(LaneSides.fluid_transposer_address(m))))
  print(string.format("[AutoOS] %s item sides buffer=%s bus=%s return=%s",
    m.id, tostring(m.side_buffer), tostring(m.side_bus_b), tostring(m.side_return or m.side_buffer)))
  print(string.format("[AutoOS] %s fluid sides buffer=%s hatch=%s",
    m.id, tostring(LaneSides.fluid_buffer_side(m)), tostring(LaneSides.fluid_hatch_side(m))))
  if m.buffer_adapter_address and m.buffer_adapter_address ~= "" then
    print(string.format("[AutoOS] %s buffer_adapter=%s %s", m.id, m.buffer_adapter_address, status_for(m.buffer_adapter_address)))
  end
end

local poll = MachinePoll.new({ config = Config, component = component })
local results = poll:poll_all()
local healthy = 0
for _, m in ipairs(Config.machines) do
  local st = results[m.id]
  if not st or not st.available then
    print(string.format("[AutoOS] %s poll=UNAVAILABLE", m.id))
  elseif st.healthy then
    healthy = healthy + 1
    print(string.format("[AutoOS] %s poll=OK active=%s has_work=%s",
      m.id, tostring(st.active), tostring(st.has_work)))
  else
    print(string.format("[AutoOS] %s poll=FAULT %s", m.id, tostring(st.fault_message)))
  end
end

if healthy == 0 then
  print("[AutoOS] DIAG: FAIL (no healthy lanes)")
else
  print(string.format("[AutoOS] DIAG: PASS (%d healthy lane(s))", healthy))
end
