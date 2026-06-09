# AutoOS Progress Log

Append-only changelog. New entries go at the bottom — never rewrite or delete prior entries.

---

## 2026-06-08 — Reference library created

- Added `references/` folder with 12 docs covering OpenComputers APIs, GTNH integration, `gt_machine`, ME network, GPU/display, maintenance, and performance pitfalls
- Sources: GTNH wiki, ocdoc.cil.li, GTNH-OC-Lua-Documentation

## 2026-06-08 — Cursor rule: read docs first

- Created `.cursor/rules/read-docs-first.mdc` (`alwaysApply: true`)
- Requires reading `README.md` and relevant `references/` files before implementation

## 2026-06-08 — Cursor rule: progress tracking

- Updated `.cursor/rules/read-docs-first.mdc` to require append-only updates to this file after each change
- Created `progress.md` as the project changelog

## 2026-06-08 — Lua visual smoke test

- Added `tests/lua_visual_test.lua`: ANSI colors, animated progress bar, AutoOS-relevant runtime checks, mock hardware tick
- For verifying local Lua install (user has Lua 5.5) before desktop emulator work
- Verified on system: `C:\Lua\lua55.exe` — Lua 5.5.0, all 9 checks passed
- Added `tests/run_visual_test.ps1` and `tests/run_visual_test.bat` — one-click runners (avoids REPL confusion)
- Fixed `tests/lua_visual_test.lua`: ASCII-only output for Windows code pages (fixes ΓöÇ mojibake); readable Platform line

## 2026-06-08 — Phase 1: Core Kernel & Maintenance Safeguards

- Added `adapter.lua`: Hardware/Adapter layer; sole hardware reader. `Adapter:poll(cache)` does a single batched `gt_machine` read per tick into a reused State Cache table (performance-pitfalls.md single-poll + table reuse).
- Added `modules/maintenance.lua` (Module 2): pure cache-only logic. Strips `§` color codes (`\194\167.`), matches the six maintenance messages + "has problems" + structure errors (`structure`/`incomplete`/`invalid`/`maintenance`/`repair`/`problem`), and emits a Priority 1 `force_shutdown` intent.
- Added `arbitrator.lua`: sole hardware writer. Flattens intents by lowest priority number (1 wins) and commits `force_shutdown` via `setWorkAllowed(false)` + `computer.beep(800, 2)`.
- Added `main.lua`: `Kernel.new(deps)` with dependency injection (machine/computer/event) so the same code runs in-game and under desktop Lua. `tick()` = poll → evaluate → commit; `run(maxTicks)` is the 0.5s-paced loop (`uptime()` + `event.pull`); README §5-style logging; in-game entry guard via `pcall(require, "component"/...)`.
- Added `tests/mock_hardware.lua`: mock `gt_machine`/`computer`/`event` with call counters and an optional `fault_at_tick` schedule (reproduces README §5).
- Added `tests/phase1_test.lua`: 39 checks — parser cases, priority-1 shutdown path, healthy no-op, single-poll + no-direct-poll contracts, 500ms tick budget, README §5 scenario, bounded `run()`. All pass via `C:\Lua\lua55.exe tests\phase1_test.lua`.
- Design notes / deviations from README's minimal tree (elaboration, not contradiction):
  - Added `adapter.lua` (named in performance-pitfalls.md but not the README topology) and kept the State Cache as a reused plain table instead of a separate module.
  - Deferred `modules/process_control.lua` (Phase 2) and `modules/resource_manager.lua` (Phase 3); no empty stubs created yet.
  - Known caveat for in-game tuning: maintenance detection uses substring matching, so a healthy sensor line literally containing "problem"/"maintenance" could false-positive. Healthy mock lines avoid these; revisit pattern precision against real `getSensorInformation()` output during in-game verification.

## 2026-06-08 — Fix GT "Problems: 0" false-positive shutdown

- Changed `modules/maintenance.lua`: removed bare `"problem"`/`"maintenance"`/`"repair"`/`"structure"` patterns; parse `Problems: N` counter (fault only when N > 0); use phrase-level structure patterns. Fixes in-game loop that shut down electrolyzer on healthy `Problems: 0 Efficiency: 0.0 %` sensor line.
- Changed `tests/phase1_test.lua`: added regression checks for `Problems: 0` (healthy) and `Problems: 1` (fault).

## 2026-06-08 — Structure fault detection + multi-line sensor logging

- Changed `modules/maintenance.lua`: added GT structure phrases (`incomplete structure`, `structure not formed`, etc.) after in-game test showed broken multiblock not detected.
- Changed `main.lua`: log every `getSensorInformation()` line as `[Sensor 1]`, `[Sensor 2]`, … — line 1 is often machine type id only.
- Changed `tests/phase1_test.lua`: added `INCOMPLETE STRUCTURE` and related structure phrase cases.

## 2026-06-08 — Log faults even when verbose=false

- Changed `main.lua`: with `verbose = false`, healthy ticks stay silent but committed faults (shutdown/beep) still print full tick log.

## 2026-06-08 — Live hardware status in logs + change detection

- Changed `adapter.lua`: poll `hasWork()` and `getAverageElectricInput()` into cache.
- Changed `main.lua`: log `[Hardware] work_allowed/active/has_work/eu_in` every printed tick; `[Arbitrator] action: none` vs `force_shutdown` (replaces misleading "unchanged"); `verbose=false` prints when any polled field or sensor line changes; `[Delta]` marker on change.
- Added `dump.lua`: one-shot in-game gt_machine diagnostic script.
- Added `start.lua`: in-game boot template with `verbose=false` + change-aware logging.
