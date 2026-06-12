# AutoOS Progress Log

Append-only changelog. New entries go at the bottom — never rewrite or delete prior entries.

---

## 2026-06-10 — Project proposal: per-multi wiring + operator displays

- Changed `README.md`: documented v1 physical assumption (one item input bus + one fluid input hatch per multiblock; no shared quad feed); expanded `config.lua` machine entries with `gt_address` and `hatch_fluid`
- Changed `README.md`: added §5 Operator Displays — full UI spec for `broker_display.lua` (batch job, machine pool table, buffer, last action) and `overseer_display.lua` (stock targets, active crafts, broker links, event log) with plain-language fields, status colors, and shared snapshot contract
- Changed `README.md`: directory layout includes display modules; Phase 5 prompt for displays; Hand-Off Test updated for per-hatch routing and broker UI expectations

## 2026-06-10 — Phase 1: Subnet broker config and load balancer

- Added `subnet_broker/config.lua`: deployment template (`subnet_id`, machines with `gt_address`/`bus_in`/`hatch_fluid`, `recipe_baselines`) + `Config.validate()`
- Added `subnet_broker/load_balancer.lua`: pure integer `calculate_distribution()` + `total_operations()`; output includes per-machine `hatch_fluid` and `allocated_volume`
- Added `subnet_broker/broker_core.lua`: print-only `process_batch()` stub (no hardware loop)
- Added `subnet_broker/start.lua`: `package.path` setup + README 15,000L verification call
- Added `subnet_broker/diag.lua`: in-game smoke test (config validate, optional `component.list` UUID walk, scenarios A/B, `PHASE 1 IN-GAME: PASS/FAIL`)
- Added `tests/phase1_broker_test.lua`: 27 desktop checks — config validation, README 3,3,2,2, hand-off 1,1,1,0, reduced pool 4,3,3, errors, broker stub
- Desktop: `C:\Lua\lua55.exe tests\phase1_broker_test.lua` — 27/27; `lua55.exe subnet_broker\diag.lua` — PASS (UUID walk skipped off-game)
- In-game checklist (operator): deploy `/home/AutoOS/subnet_broker/{config,load_balancer,broker_core,start,diag}.lua` → `loadfile(".../diag.lua")()` → `loadfile(".../start.lua")()` → optional REPL `require("broker_core").process_batch("polyethylene", 3000)`
- Note: `legacy/` Phase 1 (maintenance kernel) unchanged; root Phase 1 = config + math only

## 2026-06-10 — Phase 2: Hardware and control (subnet broker)

- Added `subnet_broker/maintenance_parse.lua`: GT sensor fault parser (`Problems: N`, tool messages, structure phrases)
- Added `subnet_broker/machine_poll.lua`: `gt_machine` proxy cache, `poll_all`, `build_active_pool` (drops maintenance faults)
- Added `subnet_broker/circuit_manager.lua`: dual push via `me_exportbus` or `transposer`; recover via transposer; `circuit_route` auto-detect
- Changed `subnet_broker/config.lua`: `circuit_vault`, `database_address`, `circuit_db_slots`, `recipe_circuit_damage`, per-machine routing sides (`bus_export_side`, `transposer_*`, `circuit_route`)
- Changed `subnet_broker/broker_core.lua`: uses `MachinePoll` when OC available; prints dropped machines; optional `push_circuit` after allocation; `BrokerCore.set_deps()` for tests
- Changed `subnet_broker/diag.lua`: component type labels for bus_in/hatch_fluid/vault/database; machine poll OK/FAULT lines; `PHASE 2 IN-GAME` summary; optional `DRY_RUN_CIRCUIT`
- Added `tests/mock_broker_hardware.lua`, `tests/phase2_broker_test.lua`: 21 checks (maintenance, pool filter, 4,3,3 safe-failure math, export/transposer circuit paths, broker integration)
- Desktop: `C:\Lua\lua55.exe tests\phase2_broker_test.lua` — 21/21; `phase1_broker_test.lua` — 27/27 regression
- In-game: wget all `subnet_broker/*.lua`; fill `database_address`, `circuit_vault`, `bus_export_side`; stock vault + ME storage bus; `diag.lua` then Safe Failure `process_batch` twice; REPL `circuit_manager` push/recover round-trip

## 2026-06-10 — Architecture revision: 1:1:1 transposer topology

- Changed `README.md`: replaced centralized buffer/vault/circuit_manager design with per-lane ME Interface + Transposer + gt_machine (1:1:1); updated mermaid, lifecycle, config contract, Phase 2/3 prompts, hand-off test
- Changed `subnet_broker/config.lua`: machines use `interface_address`, `transposer_address`, `pull_side`, `push_side`, `interface_fluid_side`; shared `database_address` + `fluid_db_slot` per recipe; removed `bus_in`, `hatch_fluid`, `circuit_vault`, export-bus fields
- Changed `subnet_broker/broker_core.lua`: `execute_lane()` — setFluidInterfaceConfiguration → transferFluid → clear; sequential one-at-a-time dispatch; `process_batch()` manual volume trigger
- Changed `subnet_broker/load_balancer.lua`: allocation map includes per-lane interface/transposer/sides
- Deleted `subnet_broker/circuit_manager.lua`: circuits via subnet ME patterns, not vault
- Changed `subnet_broker/diag.lua`, `subnet_broker/start.lua`: per-lane UUID walk; removed circuit dry-run
- Changed `tests/mock_broker_hardware.lua`, `tests/phase1_broker_test.lua`, `tests/phase2_broker_test.lua`: new schema + lane execution mocks
- Desktop: `phase1_broker_test.lua` + `phase2_broker_test.lua` regression after refactor

## 2026-06-10 — Per-lane circuit push/recover (1:1:1)

- Added `subnet_broker/circuit_manager.lua`: `push_circuit` / `recover_circuit` via lane ME Interface `setInterfaceConfiguration` + transposer `transferItem` (subnet storage, no vault)
- Changed `subnet_broker/config.lua`: `circuit_db_slots`, `recipe_circuit_damage`, `circuit_item_name`, per-lane `interface_item_slot`/`input_slot`, `circuit_damage` on recipe baselines
- Changed `subnet_broker/broker_core.lua`: circuit push before fluid in `execute_lane`; `manual_lane_test()` for in-game REPL; `recover_circuits` opt (default false on batch)
- Changed `subnet_broker/diag.lua`: optional `CIRCUIT_TEST_LANE` live push+fluid+recover block; REPL examples in header
- Changed `tests/mock_broker_hardware.lua`, `tests/phase2_broker_test.lua`: circuit push/recover + full lane cycle checks

## 2026-06-10 — Split item bus vs fluid hatch transposer sides

- Changed `subnet_broker/config.lua`: `pull_side`/`push_side` = item input bus; required `fluid_push_side`, optional `fluid_pull_side`
- Changed `subnet_broker/broker_core.lua`, `load_balancer.lua`: `transferFluid` uses fluid sides; dispatch log `item X→Y fluid A→B`

## 2026-06-10 — circuit_manager clearer proxy/database errors

- Changed `subnet_broker/circuit_manager.lua`: preflight `component.list()` check; pcall around `setInterfaceConfiguration` so bad `database_address` reports clearly

## 2026-06-10 — Dynamic database descriptors (no manual DB slots)

- Added `subnet_broker/descriptor_cache.lua`: runtime `me.store()` from subnet ME + `database.set` circuit fallback; scratch slots 1/2
- Changed `subnet_broker/config.lua`: removed `circuit_db_slots`/`fluid_db_slot`; added `descriptor_scratch`, `fluid_label` on recipes
- Changed `subnet_broker/circuit_manager.lua`, `broker_core.lua`: use descriptor_cache before set*InterfaceConfiguration
- Changed `tests/mock_broker_hardware.lua`: mock `store`, `getItemsInNetwork`, database `set`

## 2026-06-10 — Fix transferItem nil from_slot (OC arg #4)

- Changed `subnet_broker/circuit_manager.lua`: use `from_slot = 1` on circuit push (OC rejects nil for argument #4)

## 2026-06-10 — item_bus_side (shared transposer face for input bus)

- Added `subnet_broker/lane_sides.lua`: `item_bus_side` for circuits; fluids stay `fluid_pull_side`/`fluid_push_side`
- Changed `circuit_manager.lua`: `transferItem(bus, bus, ...)` push/recover on same face
- Changed `config.lua`: `item_bus_side` replaces `pull_side`/`push_side` per machine

## 2026-06-10 — Fix item routing: interface side vs bus side

- Changed `lane_sides.lua`: `interface_item_side` (ME below transposer) + `item_bus_side` (pipe/bus face)
- Changed `circuit_manager.lua`: `transferItem(iface_side, bus_side)`; 0.25s settle after stocking; clearer errors
- Changed `config.lua`: template `interface_item_side=0`, `item_bus_side=4` (pipe on right of transposer)

## 2026-06-10 — Batch circuit push: skip-on-bus, stock wait, config sides

- Changed `circuit_manager.lua`: skip push when correct circuit already on bus; wait for interface stock; retry transferItem; clearer errors (subnet stock / bus blocked)
- Changed `config.lua`: all lanes `interface_item_side=0`, `item_bus_side=4` (was 1/0 causing 0→0 in-game)

## 2026-06-10 — Config sides: interface top (1), bus bottom (0)

- Changed `config.lua`: `interface_item_side=1`, `item_bus_side=0` per physical layout (ME above transposer, bus below)
- Changed `lane_sides.lua` comment to match

## 2026-06-10 — Fix process_batch format crash (nil side)

- Changed `lane_sides.lua`: `format_sides()`, `fluid_push_side()`; type-safe side getters
- Changed `broker_core.lua`: use `format_sides` for lane log; `fluid_push_side` helper in execute_lane

## 2026-06-10 — Clearer fluid-not-in-ME error

- Changed `descriptor_cache.lua`: distinguish missing recipe fields vs fluid not stocked / label mismatch

## 2026-06-10 — Fix fluid transfer: pull from interface side (1→2)

- Changed `config.lua`: `fluid_pull_side=1` (ME top), `fluid_push_side=2` (hatch); was pulling side 2 while stocking on side 1
- Changed `lane_sides.lua`: `interface_fluid_side()`; `fluid_pull_side` defaults to interface fluid face
- Changed `broker_core.lua`: settle + retry `transferFluid`; clearer error with sides

## 2026-06-10 — Split ME fluid side vs transposer fluid sides

- Changed `lane_sides.lua`: `interface_fluid_side` = ME block face (default 0); `fluid_pull_side` = transposer face (default top)
- Changed `config.lua`: `interface_fluid_side=0`, `fluid_pull_side=1`, `fluid_push_side=2`
- Changed `broker_core.lua`: surface transposer transferFluid error + tank probe hint

## 2026-06-10 — Auto-discover fluid on transposer after ME stocking

- Added `subnet_broker/fluid_lane.lua`: probe transposer tanks; try ME interface faces 0–5 until fluid appears
- Changed `broker_core.lua`: use `stock_and_locate` instead of fixed pull side
- Changed `tests/mock_broker_hardware.lua`: `getTankLevel` for fluid probe tests

## 2026-06-10 — Fix invalid tank index on transposer probe

- Changed `fluid_lane.lua`: `fluid_mb_on_side` uses `getTankCount` + `pcall` (no crash on empty sides)
- Changed `broker_core.lua`, `diag.lua`: use safe fluid probe helpers
- Changed `tests/mock_broker_hardware.lua`: stock interface slot on setInterfaceConfiguration for same-side transfer tests

## 2026-06-11 — Full subnet_broker cleanup (bug sweep + refactor)

Fixed correctness bugs:

- `fluid_lane.lua` rewrite: lanes now PUMP `transferFluid` in a loop until the FULL allocated volume reaches the hatch (was: ≥1 mB counted as success → silent under-delivery on multi-op lanes); partial delivery fails with "delivered X of Y mB"
- `fluid_lane.lua`: side discovery probes with `transferFluid` itself (moved > 0), excludes the hatch face, and caches the working ME-side/pull-side combo per lane (`reset_cache()` to forget); tank APIs only used pcall-guarded for diagnostics
- `descriptor_cache.lua` rewrite: fluid descriptors now look up the AE2FC drop item ("drop of <Fluid>") via `getItemsInNetwork({name="ae2fc:fluid_drop"})` instead of fluid registry names that `me.store()` can't match; verifies the database slot afterward; explicit "needs a Fluid Discretizer" error when no drops exist
- `broker_core.lua`: `process_batch` continues past failed lanes and returns `(all_ok, summary)` with per-lane results (was: aborted whole batch on first failure)
- `circuit_manager.lua`: `recover_circuit` keeps transfer retries; push is idempotent and rejects mismatched circuits before touching the interface

Structural cleanup:

- Added `hw.lua`: shared proxy/network/sleep helpers (removed 3 duplicate implementations)
- `lane_sides.lua`: dropped legacy `pull_side`/`push_side` fallbacks; documented transposer-face vs ME-face side systems
- `config.lua`: tidied (single-spaced); `input_slot = 1` (dropped 0-means-1); removed duplicate `recipe_circuit_damage` map (use `recipe_baselines.circuit_damage`); side fields validated as 0-5
- `broker_core.lua`: unified option names to `push_circuits`/`recover_circuits` (dropped singular variants)
- `start.lua`: no longer auto-runs a hardware batch on boot — validates config and prints usage; wget list includes `hw.lua` + `fluid_lane.lua`
- `diag.lua`: added Fluid Discretizer check (counts `ae2fc:fluid_drop` kinds in subnet ME); default path `/home/subnet_broker`
- `tests/mock_broker_hardware.lua` rewrite: realistic mocks — transfers only move stacks that exist, fluid stocking needs a valid drop descriptor + discretizer, small interface buffer exercises the pump loop, `getTankLevel` throws "invalid tank index" on tankless faces (was: mocks fabricated successes, masking every in-game failure)
- `tests/phase2_broker_test.lua`: 30 checks incl. full-volume pumping, wrong-side auto-discovery, dry-subnet partial failure, no-discretizer error, batch continue-on-failure
- Desktop regression: phase1 13/13, phase2 30/30 pass

## 2026-06-11 — Dynamic database slots (cache hit/miss + LRU) + correct circuit pushing

Fixed wrong circuit config number being pushed when switching recipes (e.g. 14 left over fed into an 18 batch):

- `descriptor_cache.lua` rewrite: database slots are now a descriptor cache instead of fixed scratch slots 1/2.
  - CACHE HIT: known slot still holds the right circuit/fluid → reuse, no rewrite.
  - CACHE MISS: write to first empty slot; when the database is full, LRU-evict the broker-owned slot unused the longest (`database.clear` then rewrite). Foreign slots (manual GUI / other scripts) are never overwritten.
  - Every write is verified by reading the slot back; stale slots are invalidated and reallocated. LRU uses a strictly monotonic logical clock so eviction is tie-free.
  - Added `reset()` and `debug_dump()` helpers.
- `circuit_manager.lua`: after the interface stocks, the stocked stack's damage is checked against the requested circuit BEFORE transfer (`"interface stocked circuit X, expected Y"`); post-transfer sanity check confirms the right circuit landed on the bus.
- `config.lua`: replaced `descriptor_scratch` with `database_slot_count` (default 25; T1=9/T2=25/T3=81); `validate` checks it is a positive integer.
- `broker_core.lua`: `process_batch` dispatch line now logs `circuit=<damage>` per lane.
- `diag.lua`: prints database slot occupancy (used/total + first entries) and a `debug_dump()` REPL hint.
- `tests/mock_broker_hardware.lua`: added `database.clear`.
- `tests/phase2_broker_test.lua`: added cache hit, miss-to-empty, stale-slot invalidation, foreign-full rejection, LRU eviction, recipe-switch (18 not 14), and stocked-wrong-circuit guard tests.
- Desktop regression: phase1 13/13, phase2 42/42 pass.
