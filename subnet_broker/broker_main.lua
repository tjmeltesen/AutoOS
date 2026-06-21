--[[
  AutoOS — Broker OC entry (LCR lane dispatch + array watch)
  Orchestration hub — thin delegation to bootstrap and task modules.

  Public API:
    BrokerMain.build(log?)          → ctx | nil, err
    BrokerMain.run()                → false on failure (blocks in scheduler otherwise)
    BrokerMain.run_once()           → boolean
    BrokerMain.attach_tasks(ctx)    → void
    BrokerMain._build_impl(log)     → ctx (raw, no pcall wrapper)

  Run in-game:
    broker_entry              -- or: lua broker_entry.lua
    loadfile("/home/subnet_broker/broker_entry.lua")()
    loadfile("/home/subnet_broker/broker_entry.lua")("test")  -- one tick, then exit
]]
local BROKER_BUILD = "2026-06-19-me-onlyv3"

local BrokerMain = {}

function BrokerMain.build(log)
  log = log or print
  local ok_build, ctx_or_err = pcall(BrokerMain._build_impl, log)
  if ok_build then return ctx_or_err end
  return nil, tostring(ctx_or_err)
end

function BrokerMain._build_impl(log)
  return require("broker_bootstrap")._build_impl(log)
end

function BrokerMain.attach_tasks(ctx)
  require("broker_bootstrap").attach_tasks(ctx)
end

function BrokerMain.run()
  print("[Broker] starting " .. BROKER_BUILD)
  local ctx, err = BrokerMain.build()
  if not ctx then
    print("[Broker] start FAILED: " .. tostring(err))
    return false
  end

  print(string.format("[Broker] online — %s dispatch, subnet=%s, listen %d → %d, orch=%s",
    ctx.config.input_mode or "per_lane", ctx.config.subnet_id, ctx.listen_port, ctx.orch_port,
    ctx.config.orchestrator_address or "(none)"))
  print("[Broker] headless — no GPU UI; Ctrl+C to stop; use loadfile(...)(\"test\") for one tick")
  require("broker_diagnostics").print_lane_status(ctx.poll, ctx.config.machines, ctx.log)

  BrokerMain.attach_tasks(ctx)
  ctx.scheduler:run()
end

function BrokerMain.run_once()
  print("[Broker] test tick " .. BROKER_BUILD)
  local ctx, err = BrokerMain.build()
  if not ctx then
    print("[Broker] start FAILED: " .. tostring(err))
    return false
  end
  return require("broker_test_tick").run_once(ctx)
end

return BrokerMain
