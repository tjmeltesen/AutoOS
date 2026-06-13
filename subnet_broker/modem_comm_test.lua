--[[
  AutoOS — Broker raw modem comm test (worker PC)

  No network_protocols / broker_main — only PING/PONG strings.
  Use this to confirm wireless modems can talk before running broker_main.

  Ports (same as Phase 3):
    listen 106  — this PC receives jobs / pings here
    send   105  — replies to the orchestrator go here

  Edit config.lua:
    orchestrator_address = <manager PC modem UUID>   (NOT computer.address)
    (or leave "" — learn mode still works for listen + auto-PONG)

  Usage:
    lua modem_comm_test.lua info     -- print this modem + config
    lua modem_comm_test.lua listen   -- wait for messages, auto-reply PONG
    lua modem_comm_test.lua ping     -- send PING to orchestrator, wait for PONG (15s)

  Test procedure:
    1) Manager PC: lua modem_comm_test.lua listen
    2) Broker PC:  lua modem_comm_test.lua ping
    3) Broker should print "RX ... PONG". Manager should print "RX ... PING".
]]

local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/subnet_broker"
package.path = here .. sep .. "?.lua;" .. package.path

local component = require("component")
local event = require("event")
local computer = require("computer")

local LISTEN_PORT = 106
local PEER_PORT = 105
local PEER_ADDR = ""

local ok_cfg, Config = pcall(require, "config")
if ok_cfg and Config then
  PEER_ADDR = Config.orchestrator_address or PEER_ADDR
  LISTEN_PORT = Config.broker_modem_port or LISTEN_PORT
  PEER_PORT = Config.main_net_channel or PEER_PORT
end

local function modem_list()
  local list = {}
  for addr, name in component.list() do
    if name == "modem" then list[#list + 1] = addr end
  end
  return list
end

local function get_modem()
  if not component.isAvailable("modem") then return nil, "no modem component" end
  return component.modem
end

local function open_ports(m)
  local opened = {}
  for _, port in ipairs({ LISTEN_PORT, PEER_PORT }) do
    if not opened[port] then
      m.open(port)
      opened[port] = true
    end
  end
end

local function print_rx(sender, port, distance, message)
  print(string.format("[comm] RX port=%s from=%s dist=%s msg=%s",
    tostring(port), tostring(sender), tostring(distance), tostring(message)))
end

local function cmd_info()
  local m, err = get_modem()
  if not m then print("[comm] " .. err); return end
  print("[comm] === broker modem info ===")
  print("[comm] computer.address (NOT for modem.send):", computer.address())
  print("[comm] wireless:", m.isWireless())
  for i, addr in ipairs(modem_list()) do
    print(string.format("[comm] modem[%d]: %s", i, addr))
  end
  print("[comm] listen port:", LISTEN_PORT)
  print("[comm] peer port (send to orchestrator):", PEER_PORT)
  print("[comm] peer address (orchestrator modem):",
    PEER_ADDR ~= "" and PEER_ADDR or "(empty — learn from first RX or set orchestrator_address)")
end

local function cmd_listen()
  local m, err = get_modem()
  if not m then print("[comm] " .. err); return end
  open_ports(m)
  print(string.format("[comm] LISTEN on port %d — will PONG replies to sender on port %d",
    LISTEN_PORT, PEER_PORT))
  print("[comm] my modem:", modem_list()[1] or "?")
  print("[comm] Ctrl+S / reboot to stop")
  local last_hb = computer.uptime()
  while true do
    local ev, _, sender, port, distance, message = event.pull(5, "modem_message")
    if ev == "modem_message" then
      print_rx(sender, port, distance, message)
      if message == "PING" then
        local sent = m.send(sender, PEER_PORT, "PONG")
        print("[comm] auto-reply PONG ->", sender, "port", PEER_PORT, "sent:", sent)
      end
    elseif computer.uptime() - last_hb >= 30 then
      print(string.format("[comm] still listening on %d (uptime %.0fs)", LISTEN_PORT, computer.uptime()))
      last_hb = computer.uptime()
    end
  end
end

local function cmd_ping()
  local m, err = get_modem()
  if not m then print("[comm] " .. err); return end
  if PEER_ADDR == "" then
    print("[comm] orchestrator_address empty — run listen on broker, ping from manager instead")
    print("[comm] or set orchestrator_address in config.lua to manager modem UUID")
    return
  end
  open_ports(m)
  print(string.format("[comm] PING -> %s port %d", PEER_ADDR, PEER_PORT))
  print("[comm] my modem:", modem_list()[1] or "?")
  print("[comm] wireless:", m.isWireless())
  local sent = m.send(PEER_ADDR, PEER_PORT, "PING")
  print("[comm] modem.send returned:", sent)
  if not sent then
    print("[comm] send failed — check orchestrator_address is the manager MODEM uuid")
    return
  end
  print(string.format("[comm] waiting for PONG on port %d (15s)...", LISTEN_PORT))
  local deadline = computer.uptime() + 15
  while computer.uptime() < deadline do
    local ev, _, sender, port, distance, message = event.pull(1, "modem_message")
    if ev == "modem_message" then
      print_rx(sender, port, distance, message)
      if message == "PING" then
        m.send(sender, PEER_PORT, "PONG")
      elseif message == "PONG" or (type(message) == "string" and message:find("PONG", 1, true)) then
        print("[comm] SUCCESS — link OK")
        return
      end
    end
  end
  print("[comm] TIMEOUT — no PONG. Is manager running `lua modem_comm_test.lua listen`?")
  print("[comm] Check: wireless modems, orchestrator_address = manager modem UUID, manager listens on 105")
end

local mode = (arg and arg[1]) or "info"
if mode == "listen" then
  cmd_listen()
elseif mode == "ping" then
  cmd_ping()
else
  cmd_info()
  print("[comm] commands: lua modem_comm_test.lua listen | ping | info")
end
