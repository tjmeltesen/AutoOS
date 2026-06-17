# GTCEU + LCR → AutoOS GTNH/OC Port Map

Reference sources:

- [`cc_gtceu_multipurpose-main/multipurpose.lua`](cc_gtceu_multipurpose-main/multipurpose.lua) — CC round-robin multi-multiblock
- [`LCR Universal Automation.lua`](LCR%20Universal%20Automation.lua) — **primary** GTNH OC per-lane transposer loop
- Target: [`subnet_broker/lane_dispatch.lua`](../subnet_broker/lane_dispatch.lua)

## v1 locked

| Setting | Value |
|---------|-------|
| `input_mode` | `per_lane` |
| `completion_mode` | `both` (adapter edge + LCR drain gate) |
| Transposers | Dual per lane: item + fluid |

## LCR → `lane_dispatch.lua` (primary)

| LCR phase | LCR API | AutoOS module / field |
|-----------|---------|------------------------|
| Wait buffer | `getTankLevel`, `getSlotStackSize` on `s_buffer` | `LaneDispatch:_buffer_ready()` — item TP + fluid TP |
| Settle | `os.sleep(0.1)` | `settle_s` deadline after buffer detected |
| Transfer fluids | `transferFluid(s_buffer, s_machine, 1e6)` loop | `fluid_transposer_address`, `side_fluid_buffer`, `side_fluid_hatch` |
| Transfer items | `transferItem` slots `chest_slot_start..size` | `item_transposer_address`, `side_buffer`, `side_bus_b` |
| Wait fluid drain | `hatch.getTankLevel(s_machine, 1) == 0` | `_fluid_drained()` on fluid TP |
| Wait item drain | `bus.getSlotStackSize(s_machine, 2) == 0` | `_item_drained()` — slot after `circuit_bus_slot` |
| Extract circuit | `transferItem(s_machine, s_circuit, size, 1)` | `side_bus_b` → `side_return`, slot `circuit_bus_slot` |
| Wait AE import | `getSlotStackSize(s_circuit, 1) == 0` | `WAIT_IMPORT` state |

## GTCEU → AutoOS (scheduling only)

| GTCEU | AutoOS |
|-------|--------|
| `findAvailableOutputRR()` | Per-lane FSM; skip faulted lanes in `array_watch`; `do_round_robin` reserved for v2 central |
| `pushAll` / `pushItems` / `pushFluids` | LCR transfer on dual transposers |
| `setProgrammedCircuit` + paper `C:N` | **Not ported** — GTNH integrated circuit in bus slot 1 |
| `getBlockId` auto-discovery | Explicit UUIDs in `config.lua` + `probe_transposer.lua` |
| CC `parallel.waitForAll` | Sequential `tick_lane` per lane per broker tick |
| KubeJS peripherals | `gt_machine` adapter (`isMachineActive`, `getSensorInformation`, `setWorkAllowed`) |

## AutoOS additions (LCR gaps)

| Concern | Module |
|---------|--------|
| Maintenance fault | `maintenance_parse.lua`, `array_watch:_handle_fault()` |
| Orchestrator telemetry | `network_protocols.lua`, `BROKER_HEALTH` / `BROKER_EVENT` |
| Per-lane independence | Per-lane FSM in `lane_dispatch.lua` (not LCR global lock) |
| Adapter completion | `poll_status.active` / `isMachineActive()` in `WAIT_COMPLETE` |
| Explicit config | `config.lua` UUIDs + side integers |

## Side naming

| LCR | Config |
|-----|--------|
| `s_buffer` (items) | `side_buffer` on item transposer |
| `s_buffer` (fluids) | `side_fluid_buffer` on fluid transposer (defaults to `side_buffer`) |
| `s_machine` (bus) | `side_bus_b` |
| `s_machine` (hatch) | `side_fluid_hatch` |
| `s_circuit` | `side_return` |

## Non-portables

- CC:Tweaked `peripheral.wrap`, `pushItems`, `pushFluid`
- KubeJS `greg_ex.js` / `coords_and_id.js`
- GTCEU paper circuit tokens
- CC monitor UI (`monitorLoop`)
