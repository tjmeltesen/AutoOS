--[[
  AutoOS — Registry adapter
  Single canonical site for all mutations to the static registry object.
  No other module writes directly to registry._poll_results or
  registry.release_transport_locks.
]]
local RegistryAdapter = {}

function RegistryAdapter.seed_runtime(registry, now_fn, log_fn)
  -- belt-and-suspenders: broker_boot may have already seeded with print;
  -- re-seed with the caller's log function so output goes to the right place
  pcall(registry.seed, now_fn, log_fn, registry.get_circuit_manager())
end

function RegistryAdapter.inject_transport_locks(registry, rob)
  -- Expose transport lock release so LaneWorker can free the transposer
  -- after stocking completes (Phase 4) instead of holding it through
  -- the entire craft wait (Phase 5).
  registry.release_transport_locks = function(machine_id)
    rob:release_transport_locks(machine_id)
  end
end

return RegistryAdapter
