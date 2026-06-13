local sep = package.config:sub(1, 1)
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "/home/orchestrator"
local f = loadfile(here .. sep .. "modem_comm_test.lua")
if not f then print("[comm] cannot load modem_comm_test.lua") else f("ping") end
