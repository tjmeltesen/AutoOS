--[[
  AutoOS Subnet Broker — Array Watch diagnostic

  Run from OC shell:
    loadfile("/home/subnet_broker/diag.lua")()

  Extra tools:
    loadfile("/home/subnet_broker/probe_transposer.lua")()
    loadfile("/home/subnet_broker/test_recover_transfer.lua")("machine_01")
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local Config = require("config")
local MachinePoll = require("machine_poll")

local ok_cfg, cfg_err = Config.validate(Config)
if ok_cfg then
  print("[AutoOS] Config validate: OK")
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
for addr, ctype in component.list() do
  addrs[addr] = ctype
end

local function status_for(addr)
  local ctype = addrs[addr]
  if ctype then return "FOUND " .. ctype end
  return "MISSING"
end

for _, m in ipairs(Config.machines) do
  print(string.format("[AutoOS] %s gt=%s %s", m.id, m.gt_address, status_for(m.gt_address)))
  print(string.format("[AutoOS] %s tp=%s %s", m.id, m.transposer_address, status_for(m.transposer_address)))
  print(string.format("[AutoOS] %s sides buffer=%s bus=%s return=%s",
    m.id, tostring(m.side_buffer), tostring(m.side_bus_b), tostring(m.side_return or m.side_buffer)))
  if m.buffer_adapter_address and m.buffer_adapter_address ~= "" then
    print(string.format("[AutoOS] %s buffer_adapter=%s side=%s %s",
      m.id, tostring(m.buffer_adapter_address), tostring(m.buffer_adapter_side), status_for(m.buffer_adapter_address)))
  end
end

if Config.database_address then
  print(string.format("[AutoOS] database=%s %s", Config.database_address, status_for(Config.database_address)))
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
