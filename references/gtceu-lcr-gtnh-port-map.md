# GTCEU + LCR → AutoOS GTNH/OC Port Map

Reference sources:

- [`cc_gtceu_multipurpose-main/multipurpose.lua`](cc_gtceu_multipurpose-main/multipurpose.lua) — CC round-robin multi-multiblock
- [`LCR Universal Automation.lua`](LCR%20Universal%20Automation.lua) — **primary** GTNH OC per-lane transposer loop
- Target: [`subnet_broker/lane_dispatch.lua`](../subnet_broker/lane_dispatch.lua)

## v1 modes

| Setting | `per_lane` | `central` |
|---------|------------|-----------|
| `input_mode` | AE deposit per lane buffer | AE deposit to shared central chest/tank |
| Input FSM | `lane_dispatch.lua` idle→transfer | `central_dispatch.lua` RR push |
| Lane tail | wait_complete→extract→return | same |
| `do_round_robin` | lane tick order only | `findAvailableMachineRR()` in central_dispatch |

Default template: `per_lane`. Set `input_mode = "central"` + `Config.central` UUIDs when using shared buffer.

## LCR → `lane_dispatch.lua` (per_lane tail + central handoff)

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

## GTCEU multipurpose → `central_dispatch.lua` (central mode)

| Multipurpose | AutoOS |
|--------------|--------|
| `hasItemsInInput` / `hasFluidsInInput` | `CentralDispatch:_central_buffer_ready()` |
| `findAvailableOutputRR()` | `CentralDispatch:find_available_machine_rr()` |
| `output:isEmpty()` | `_machine_available()` — idle poll + empty bus/hatch/return |
| `pushAll` / `pushItems` / `pushFluids` | `_transfer_central_to_machine()` via central item/fluid TPs |
| `doRoundRobin` | `Config.do_round_robin` |

| Central buffer | `Config.central.side_buffer` on central item + fluid TPs |
| Per-machine route | `central_item_side`, `central_fluid_side` on central TPs |
| Lane bus/hatch/return | unchanged `side_bus_b`, `side_fluid_hatch`, `side_return` on lane TPs |

## GTCEU → AutoOS (scheduling only)

| GTCEU | AutoOS |
|-------|--------|
| `findAvailableOutputRR()` | `central_dispatch.lua` when `input_mode=central`; else per-lane FSM in `array_watch` |
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
