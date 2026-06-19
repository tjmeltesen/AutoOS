--[[
  AutoOS — Broker Bootloader (MMU Phase 1)

  Replaces the initialization portion of broker_main.lua:BrokerMain.build().
  Validates config, builds the static hardware registry, returns it.

  Usage:
    local Boot = require("broker_boot")
    local registry = Boot.boot()
    if not registry then error("boot failed") end
    -- All proxies, DB slots, and machine entries are pre-resolved.
    -- The registry is READ-ONLY — treat it as ROM for the broker lifetime.
]]

local function boot()
  local component = require("component")
  local computer  = require("computer")
  local Config    = require("config")
  local Registry  = require("registry")

  local ok, err = Config.validate(Config)
  if not ok then
    return nil, "config invalid: " .. tostring(err)
  end

  local registry, reg_err = Registry.build(Config, component)
  if not registry then
    return nil, tostring(reg_err)
  end

  -- Seed runtime deps that can't be captured at build time
  local CircuitManager = require("circuit_manager")
  local circuit_mgr = CircuitManager.new({
    config = Config,
    component = component,
    descriptor_cache = nil, -- ROM-pinned by registry; descriptor_cache not needed
    yield_sleep = function() end, -- replaced after scheduler is built
  })
  registry:seed(computer.uptime, print, circuit_mgr)

  return registry
end

return {
  boot = boot,
  version = "2026-06-19-mmu-phase1",
}
