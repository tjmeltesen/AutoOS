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

## 2026-06-08 — Compact sensor logging (fix tick-counter spam)

- Changed `main.lua`: ignore GT uptime/tick sensor lines for `[Delta]` change detection; compact sensor log prints only changed or fault-relevant lines unless `verbose=true`.

## 2026-06-08 — verbose=false truly silent; monitor opt-in

- Changed `main.lua`: `verbose=false` prints only on fault shutdown; `monitor=true` opt-in for change logging; dropped eu_input from change detection (rolling average jitter); default verbose is now false unless explicitly true.
- Changed `start.lua`: document `verbose` vs `monitor` flags.

## 2026-06-08 — Phase 1 in-game validation (Industrial Electrolyzer, GTNH)

### Deployment (OpenComputers)

- Layout on computer HDD: `/home/AutoOS/{main,adapter,arbitrator}.lua`, `/home/AutoOS/modules/maintenance.lua`, boot via `/home/start.lua`.
- Import via `wget` **raw** URLs from `https://github.com/tjmeltesen/AutoOS` (repo HTML URL saves a single useless file named `AutoOS`; use `raw.githubusercontent.com/.../main/<file>`).
- `start.lua` sets `package.path` for the `/home/AutoOS/` subfolder; requires Internet Card for `wget`.
- Recommended in-game boot: `verbose = false` (silent unless fault shutdown); `monitor = true` only when debugging state changes.

### Logging modes (final behavior)

| Flag | Behavior |
|------|----------|
| `verbose = false` (default) | Silent; prints only on fault `force_shutdown` (+ beep) |
| `monitor = true` | Also logs when `work_allowed` / `active` / non-noisy sensor lines change |
| `verbose = true` | Every tick + full sensor dump (debug) |

- `[Arbitrator] action: none` means AutoOS took no action — not "machine state unchanged". Live state is `[Hardware] work_allowed/active/has_work/eu_in`.
- GT uptime/tick counter sensor lines (`Total Time…`, `in ticks:`) are ignored for change detection to avoid log spam.

### In-game test matrix (user session)

| Tick | Event | Sensor / hardware | AutoOS action | Verdict |
|------|-------|-------------------|---------------|---------|
| ~164 | Turn machine on | `work_allowed=true`, `active=false`, `eu_in=0` | none | Correct |
| ~290 | Turn machine off (manual) | `work_allowed=false`, `active=false` | none | Correct — manual off ≠ fault |
| ~335 | Broke maintenance hatch block | `Problems: 0`, pollution/parallel changed | none | Correct per rules — hatch removal ≠ maintenance counter |
| ~500 | Power fail during recipe | `0 EU / 16896 EU`, `0 EU/t`, `active=false` | none | Correct by design — power fail is GT self-pause, not AutoOS shutdown |
| (later) | Real maintenance issue | `Problems: N` where N > 0 | `force_shutdown` + beep | **Validated** — core Phase 1 contract works in-game |

### Key findings

- **False-positive fix confirmed:** healthy `Problems: 0 Efficiency: …` no longer triggers shutdown after `maintenance.lua` counter parse fix.
- **Real maintenance confirmed:** `Problems: 1+` (and tool-repair text) triggers Priority 1 shutdown as intended.
- **Structure incomplete:** breaking a hatch did not surface `INCOMPLETE STRUCTURE` (or `Problems > 0`) in `getSensorInformation()` for this electrolyzer — structure detection cannot fire without matching sensor text. Use `dump.lua` per-machine if tuning needed.
- **Power loss:** visible in sensor EU lines and `[Hardware]` but intentionally out of Phase 1 scope (see `references/maintenance-and-safety.md`).

### Desktop tests

- `C:\Lua\lua55.exe tests\phase1_test.lua` — 43/43 checks passing after all Phase 1 iterations.

### Phase 1 status: **complete & in-game validated**

Ready for **Phase 2** (Multiblock Process Control / hysteresis, `modules/process_control.lua`, ME inventory reads).

### Carry-forward for next session

- Repo: `https://github.com/tjmeltesen/AutoOS`
- In-game update: `wget -f` `main.lua`, `modules/maintenance.lua`, `start.lua` from raw URLs after pushes.
- Do not re-litigate: manual off, power fail, hatch block break — expected no-ops unless sensor rules match.
- Optional Phase 1.5 (not started): power-fail alert (log/beep, no shutdown); structure detection if real sensor phrases are captured via `dump.lua`.

## 2026-06-08 — Phase 2: Multiblock Process Control & Leveling Engine

- Added `modules/process_control.lua` (Module 1, Priority 3): pure cache-only dual-threshold hysteresis. `ProcessControl.new({label, low, high, kind})` returns a stateful instance holding its `active` flag across ticks; below `low` -> ACTIVE, above `high` -> IDLE, inside the deadband -> hold (no flapping). Emits `{priority=3, module="process_control", action="set_work_allowed", state, stock, reason}`. Exposes `.evaluate(cache)` as a field-function so the kernel's `mod.evaluate(cache)` loop is unchanged across static (maintenance) and instance (process control) modules. Reads `cache.stock[label]` only; holds state when stock is unknown.
- Changed `adapter.lua`: `Adapter.new(machine, computer, me, targets)` now takes an optional ME proxy + target list. New `poll_inventory(cache)` runs one filtered `getItemsInNetwork({label=...})` per item target and a single `getFluidsInNetwork()` scan for fluid targets, writing counts into a reused `cache.stock` table (cleared, not reallocated, per performance-pitfalls.md). No ME proxy => `cache.stock = nil` and Phase 1-only behavior.
- Changed `arbitrator.lua`: added `set_work_allowed` action and change-only writes — `commit(intents, cache)` skips `setWorkAllowed()` when the machine is already in the requested state (compares `cache.work_allowed`). `force_shutdown` write is likewise gated on change; the `computer.beep(800,2)` alarm fires only when a Priority 1 shutdown actually flips the machine off. Result now carries `action` for logging. Backward-compatible when `cache` is nil (always writes).
- Changed `main.lua`: `Kernel.new` builds the adapter with `me`+targets and appends `ProcessControl.new(deps.process_control)` to `self.modules` only when both an ME proxy and a product config are supplied (otherwise Phase 1 only). `tick()` passes `self.cache` to `arbitrator:commit`. Added `[Process Control]` telemetry log line (tracked stock + ACTIVE/IDLE + bands) and generalized the winning-intent / arbitrator-action logging beyond maintenance. `build_oc_deps` now binds `component.me_interface` (preferred) or `component.me_controller` and a default Soldering Alloy config when a proxy is present.
- Changed `start.lua`: binds `me = me_interface or me_controller` and a documented `process_control = {label, low, high, kind}` block (enabled only when `me` is non-nil).
- Changed `tests/mock_hardware.lua`: added a mock `me` proxy (`getItemsInNetwork(filter)` honoring `{label=}`, `getFluidsInNetwork()`), `getItemsInNetwork`/`getFluidsInNetwork`/`me_calls` counters, `stock`/`fluids` state, and `set_stock`/`set_fluid` helpers; `me` exposed via `deps()`. `setWorkAllowed(true)` now restores `active` (machine resumes) for hysteresis-on tests.
- Added `tests/phase2_test.lua`: 35 checks — construction guards, hysteresis bands + deadband hold, no-flapping sweep (<=2 transitions), unknown-stock hold, kernel ON/OFF drive, arbitrator change-only writes, Priority 1 > Priority 3 override + beep, fluid-target path, single ME poll point, zero-hardware-call module contract, and Phase 1-only fallback without an ME proxy. All pass.

### Desktop tests

- `C:\Lua\lua55.exe tests\phase1_test.lua` — 43/43 (no regressions from the change-only-write refactor).
- `C:\Lua\lua55.exe tests\phase2_test.lua` — 35/35.

### Phase 2 status: **complete (desktop-validated)**; in-game validation pending.

### Carry-forward for next session

- In-game: connect an ME interface/controller adapter, set the `process_control` label/thresholds in `start.lua` to the real product this machine refills, and confirm hysteresis drives `setWorkAllowed` without flapping. Watch the per-tick budget if the ME network is large (use filtered queries; consider throttling per performance-pitfalls.md).
- Next: **Phase 3** (Raw Resource Management & Projection — ring buffers, consumption velocity ΔR, time-to-depletion; `modules/resource_manager.lua`, Priority 2 soft-sleep).

## 2026-06-08 — Read-only status monitor (pre-Phase-4 helper)

- Added `display.lua`: a thin, READ-ONLY status panel for in-game Phase 2 verification. `Display.new(gpu, screen, opts)` binds the screen, clamps to a compact resolution (default 60x16), and `:render(snapshot)` draws a fixed panel (machine state, power, process-control stock/band/state, arbitrator action, maintenance banner) with width-padded lines and palette colors. It never calls `setWorkAllowed`, never polls the machine/ME network, and holds no control state — it only consumes a snapshot built from the already-computed cache + arbitrator result. This is NOT the Phase 4 charting UI (no history buffers, braille sparklines, or navigation), just visual feedback while validating Phase 2.
- Changed `main.lua`: `Kernel.new` builds `self.display` only when `deps.gpu` is provided (construction wrapped in `pcall`; headless on failure). `tick()` renders `self:_snapshot(result)` at the end inside a `pcall` so a display fault can never stall the safety/control loop (display is disabled after a render error). Added `_snapshot(result)` which pulls only from cache + result. `build_oc_deps` now binds `component.gpu` + `component.screen.address` when both are available.
- Changed `start.lua`: auto-wires `gpu`/`screen` when both components are present, documented as informational/no-control; omit them to run headless.
- Changed `tests/mock_hardware.lua`: added a mock `gpu` (bind/getResolution/maxResolution/setResolution/getSize/setForeground/setBackground/fill/set) that records rendered rows in `state.gpu_rows` and `gpu_set`/`gpu_fill` counters; exposed via the returned table.
- Added `tests/display_test.lua`: 21 checks — construction/bind/resolution/clear, content rendering (title/tick/machine/product/band/state/arbitrator), fault banner, READ-ONLY contract (zero machine/ME calls during render), Phase 1-only snapshot (no PC section), and kernel-with-display preserving control behavior + the single-poll contract + headless fallback.

### Desktop tests (all green)

- `C:\Lua\lua55.exe tests\phase1_test.lua` — 43/43 (unchanged).
- `C:\Lua\lua55.exe tests\phase2_test.lua` — 35/35 (unchanged).
- `C:\Lua\lua55.exe tests\display_test.lua` — 21/21.

### Notes / deviations

- Deliberately scoped to a read-only single-panel monitor (not the interactive "add/manage items" terminal). A runtime management console + multi-item/multi-machine views still require a multi-target config refactor and are best landed with the Phase 4 display work.
- In-game: also `wget -f` the new `display.lua` (and updated `main.lua`/`start.lua`) from the raw repo URLs; connect a GPU (Tier 2+ for color) + screen to see the panel.

## 2026-06-08 — Phase 2: ME autocraft integration (process control)

- Changed `modules/process_control.lua`: added `mode` config (`"machine"` | `"craft"` | `"both"`, default `"machine"` for desktop tests). When ACTIVE and stock `< high`, craft/both modes emit a Priority 3 `request_craft` intent with `amount = high - stock` if `cache.craftable[label]` is true (item targets only). Machine mode unchanged. Module may return one intent or an array (both mode).
- Changed `adapter.lua`: `poll_craftables(cache)` runs one filtered `getCraftables({label})` per item target into reused `cache.craftable[label]` booleans (adapter is sole ME reader).
- Changed `arbitrator.lua`: accepts optional `me` proxy; commits `request_craft` via `getCraftables({label})[1].request(amount, prioritize_power)`; tracks `craft_jobs[label]` and throttles duplicate requests while `AECraftingJob` is still active. `commit()` now applies **all** intents at the winning priority level (e.g. machine + craft together in `"both"` mode). Result carries `craft` and `machine` sub-results.
- Changed `main.lua`: collects intent arrays from modules; passes `me` to arbitrator; logs craft commits/skips; snapshot/display include `mode`, `craftable`, and craft result.
- Changed `start.lua`: default `mode = "craft"` with documented options; ME autocraft requires an AE recipe matching `label`.
- Changed `display.lua`: shows mode, ME recipe availability, and last craft request/skip on the status panel.
- Changed `tests/mock_hardware.lua`: `getCraftables(filter)`, `request()` with `AECraftingJob` mock, `set_craftable`/`set_craft_pending` helpers, `craft_request` counter.
- Changed `tests/phase2_test.lua`: +14 craft checks (craft intent amount, craft-only vs machine-only, kernel commit, throttle, both mode, maintenance blocks craft, zero-direct-call contract). 49/49 passing.

### Desktop tests

- `C:\Lua\lua55.exe tests\phase1_test.lua` — 43/43.
- `C:\Lua\lua55.exe tests\phase2_test.lua` — 49/49.
- `C:\Lua\lua55.exe tests\display_test.lua` — 21/21.

### In-game setup for ME autocraft

- Ensure the tracked `label` in `start.lua` has a **craftable AE pattern** (visible in ME terminal → craftables).
- Set `mode = "craft"` for ME-only leveling, `"both"` to also run the gt_machine, or `"machine"` for physical-line-only (previous behavior).
- Re-`wget -f` updated files: `modules/process_control.lua`, `adapter.lua`, `arbitrator.lua`, `main.lua`, `display.lua`, `start.lua`.

## 2026-06-08 — README: emphasize ME autocraft leveling

- Changed `README.md`: updated vision, architecture diagram, priority matrix, and functional requirements to highlight ME autocraft (`getCraftables` → `request`) alongside gt_machine control; expanded Phase 2 with `craft`/`machine`/`both` modes and prerequisites; added §5 in-game setup (layout, `process_control` config, recipe verification); refreshed file topology and desktop test commands; fixed broken code-fence formatting in the old §5 section.

## 2026-06-08 — Fix fluid ME autocraft (Oxygen / dual interface)

- Root cause: `process_control` only issued crafts when `kind == "item"`; fluids (e.g. Oxygen) were excluded even with a valid AE fluid pattern.
- Changed `modules/process_control.lua`: crafts allowed for fluids; optional `craft_label`; intent uses `cache.craft_labels[label]` when adapter resolves an alternate filter (e.g. `drop of Oxygen`).
- Changed `adapter.lua`: `poll_craftables` now checks fluid targets; tries `craft_label` then `drop of <name>` for fluid discretizer setups; stores `cache.craft_labels`.
- Changed `main.lua`: passes `craft_label` in targets; logs ticks when craft is skipped (`craft_reason`) even with `verbose=false`.
- Added `me_dump.lua`: in-game ME diagnostic — lists matching fluids/items/craftables and suggests `start.lua` fields.
- Changed `tests/phase2_test.lua`: fluid craft intent check.

## 2026-06-08 — Fix duplicate ME craft orders (200k + 200k = 400k)

- Cause: each request used `amount = high - stock`; ME fluid stock often lags in `getFluidsInNetwork`, so a second full-deficit craft fired before counts updated (job `isDone()` can return true while stock still reads low).
- Changed `modules/process_control.lua`: optional `max_craft` caps each single `request()` amount.
- Changed `arbitrator.lua`: 10s cooldown per craft label unless polled stock rose since last request; tracks `craft_state` with stock snapshot at commit.
- Changed `start.lua`: Oxygen fluid example with realistic mB bands (`low=8000`, `high=32000`, `max_craft=16000`).
- Changed `tests/phase2_test.lua`: `max_craft` cap check.
