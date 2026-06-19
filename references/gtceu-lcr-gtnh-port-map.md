# GTCEU + LCR → AutoOS GTNH/OC Port Map

Reference sources:

- [`cc_gtceu_multipurpose-main/multipurpose.lua`](cc_gtceu_multipurpose-main/multipurpose.lua) — CC round-robin multi-multiblock
- [`LCR Universal Automation.lua`](LCR%20Universal%20Automation.lua) — **primary** GTNH OC per-lane transposer loop
- Target: [`subnet_broker/lane_dispatch.lua`](../subnet_broker/lane_dispatch.lua)

## v1 modes

| Setting | `per_lane` | `central` |
|---------|------------|-----------|
| `input_mode` | AE deposit per lane buffer | AE deposit to shared central chest (storage bus) |
| Input FSM | `lane_dispatch.lua` idle→transfer | `central_dispatch.lua` adapter + stabilize → RR handoff |
| Lane tail | wait_complete→extract→return | same |
| `do_round_robin` | lane tick order only | `find_available_machine_rr()` in central_dispatch |

Default template: `central`. Set `Config.central.buffer_adapter_address` + per-lane transposer UUIDs.

## LCR → `lane_dispatch.lua` (per_lane + central handoff)

| LCR phase | LCR API | AutoOS module / field |
|-----------|---------|------------------------|
| Wait buffer | `getTankLevel`, `getSlotStackSize` on `s_buffer` | `LaneDispatch:_buffer_ready()` — item TP + fluid TP |
| Settle | `os.sleep(0.1)` | `settle_s` deadline after buffer detected |
| Transfer items | `transferItem` slots `chest_slot_start..size` | **items first** — `item_transposer_address`, `side_buffer`, `side_bus_b` |
| Transfer fluids | `transferFluid(s_buffer, s_machine, 1e6)` loop | **after items, if staged** — `fluid_transposer_address`, `side_fluid_buffer`, `side_fluid_hatch` |
| Wait fluid drain | `hatch.getTankLevel(s_machine, 1) == 0` | `_fluid_drained()` on fluid TP |
| Wait item drain | `bus.getSlotStackSize(s_machine, 2) == 0` | `_item_drained()` — slot after `circuit_bus_slot` |
| Extract circuit | `transferItem(s_machine, s_circuit, size, 1)` | `side_bus_b` → `side_return`, slot `circuit_bus_slot` |
| Wait AE import | `getSlotStackSize(s_circuit, 1) == 0` | `WAIT_IMPORT` state |

## Central buffer → `central_dispatch.lua` (storage bus, no central TPs)

| Concern | AutoOS |
|---------|--------|
| `hasItemsInInput` | `CentralDispatch:_item_fingerprint()` on item chest adapter |
| AE trickle-in guard | `Config.central.stabilize_s` (default 3s) — fingerprint unchanged |
| Fluid required | **No** for dispatch admission; fluid queue steps are optional and run when present |
| Descriptor DB | Shared `Config.database_address` + `database_slot_count` (broker-owned slots) |
| Lane IF control | Per-lane `machine.interface_address`; items and fluids are queued, with fluids stocked one-at-a-time on `interface_fluid_side` |
| `findAvailableOutputRR()` | `CentralDispatch:find_available_machine_rr()` |
| `pushAll` / central transposers | **Not used** — subnet AE routes to lane dual interface; lane TPs transfer |
| `doRoundRobin` | `Config.do_round_robin` |

| Central monitor | `Config.central.buffer_adapter_address` + `buffer_adapter_side` on item chest |
| Central fluid source | `fluid_adapter_address` + `fluid_adapter_side` feed central fluid queue entries from tank controller APIs |
| Lane extract | `side_buffer` / `side_fluid_buffer` on lane transposers (dual interface face) |
| Dual IF pull | Transposer reads subnet storage through adjacent dual interface — not a separate chest face |
| Queue model | Dual-track queue: item and fluid tracks can progress in parallel; consecutive same-kind steps wait for that track's buffer face to empty |
| Post-transfer cleanup | Clear IF configs, then `database.clear` broker-owned slots (`release_slots`) |

## GTCEU → AutoOS (scheduling only)

| GTCEU | AutoOS |
|-------|--------|
| `findAvailableOutputRR()` | `central_dispatch.lua` when `input_mode=central`; else per-lane FSM in `array_watch` |
| Lane push | LCR transfer on dual lane transposers |
| `setProgrammedCircuit` + paper `C:N` | **Not ported** — GTNH integrated circuit in bus slot 1 |
| `getBlockId` auto-discovery | Explicit UUIDs in `config.lua` + `probe_transposer.lua` |
| CC `parallel.waitForAll` | Sequential items then fluids per lane tick |
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
