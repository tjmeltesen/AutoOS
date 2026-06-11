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
