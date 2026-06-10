# Phase 3 Implementation Guide — Raw Resource Management & Projection

**Audience:** An agent implementing Phase 3 without reading the entire codebase.  
**Status:** Phase 1 complete (in-game validated). Phase 2 complete (desktop + in-game validated for Oxygen ME craft). Phase 3 not started.  
**Read first:** `README.md` §3–§4, `references/autoos-api-mapping.md` (Phase 3 row), `references/me-network-api.md` (consumption velocity snippet), `references/performance-pitfalls.md`, `progress.md` (2026-06-09 power/stored-EU notes).

---

## 1. What Phase 3 Must Do

| Goal | Contract (README §3) |
|------|----------------------|
| **Track consumption** | Ring-buffer history of ME stock per watched label; compute velocity \(\Delta R = (R_t - R_{t-\Delta t}) / \Delta t\). |
| **Predict depletion** | Time-to-depletion \(TTD = R / \|\Delta R\|\) when \(\Delta R < 0\). |
| **Alert early** | Log/beep when \(TTD < 1800\) s (30 min) for a configured input. |
| **Soft sleep (Priority 2)** | When a **required input** is missing or depleting unsafely, emit intent to **pause the line** (`setWorkAllowed(false)`) — **not** a maintenance shutdown. Maintenance (P1) still wins. Process control (P3) resumes when inputs recover. |

Phase 3 is **logic + cache history + Priority 2 intents**. It is **not** charting (Phase 4) and **not** new ME craft throttling (Phase 2 arbitrator already handles that).

---

## 2. What Phase 3 Must **Not** Do

- **Do not** poll hardware from modules — only `adapter.lua` touches `gt_machine` / ME APIs.
- **Do not** call `setWorkAllowed()` or `request_craft()` outside `arbitrator.lua`.
- **Do not** use `allItems()` in the tick loop.
- **Do not** allocate new tables every tick for history (reuse ring buffers; see §6).
- **Do not** re-implement maintenance detection (P1) or hysteresis leveling (P3 process_control).
- **Do not** build braille/history charts — Phase 4 pulls Phase 3 buffers for display only.
- **Do not** treat `eu_in=0` on an idle machine as “no power” — see §12 and in-game validation in `progress.md`.

---

## 3. Architecture (Unchanged Layers)

```
adapter:poll()  →  cache (stock, sensor, power, history, velocities)
       ↓
modules: evaluate(cache)  →  intents { priority, action, ... }
       ↓
arbitrator:commit(intents, cache)  →  setWorkAllowed / request_craft (sole writer)
```

**Tick budget:** ≤ **500 ms** (`main.lua` `TICK_INTERVAL = 0.5`). Extra ME polls for Phase 3 inputs must stay filtered (`{ label = "..." }`) and count toward the same single poll point pattern.

---

## 4. Codebase Map (Minimum Reading List)

| File | Role today | Phase 3 change |
|------|------------|----------------|
| `adapter.lua` | Sole hardware reader; `cache.stock`, `cache.craftable`, power fields | Append history samples after inventory poll; optional extra **filtered** ME targets for inputs |
| `modules/process_control.lua` | P3 hysteresis; `request_craft` + optional `set_work_allowed` | **No behavior change** unless soft-sleep must suppress craft (see §8) |
| `modules/maintenance.lua` | P1 `force_shutdown` | **No change** |
| `modules/resource_manager.lua` | **Does not exist** | **Create** — P2 soft sleep + TTD alerts |
| `arbitrator.lua` | Commits P1/P3; craft throttling | Add P2 action handler (`soft_sleep` / reuse `set_work_allowed(false)`) |
| `main.lua` | Wires modules, display, logging | Register `ResourceManager`; extend `targets` list; snapshot/log hooks |
| `display.lua` | Read-only panel | Optional: TTD / input status rows; **eu_in fix** (§12) |
| `start.lua` | User config | Add `resource_manager = { inputs = {...} }` block |
| `tests/mock_hardware.lua` | Mocks gt_machine + ME | History-friendly stock helpers |
| `tests/phase3_test.lua` | **Does not exist** | **Create** — velocity, TTD, P2 overrides P3, alert threshold |

**Intent collection pattern** (`main.lua` `Kernel:tick`): modules expose `.evaluate(cache)` returning `nil`, one intent table, or an **array** of intents (process_control already does this). Resource manager should return **one** P2 intent or `nil`.

---

## 5. State Cache — Current Fields (Phase 2)

After `adapter:poll(cache)` today:

| Field | Type | Source |
|-------|------|--------|
| `sensor` | string[] | `getSensorInformation()` |
| `work_allowed`, `active`, `has_work` | bool / nil | gt_machine |
| `eu_input` | number / nil | `getAverageElectricInput()` — **often 0 when idle** |
| `stored_eu` | number / nil | Sensor parse preferred; see `stored_eu_source` |
| `stored_eu_source` | `"sensor"` / `"component"` / nil | Which path populated `stored_eu` |
| `power_loss` | bool | Sensor text + drained-buffer rule |
| `power_available` | bool | `not power_loss` |
| `stock` | `{ [label] = count }` | ME filtered poll |
| `craftable`, `craft_labels` | tables | ME `getCraftables` |
| `time` | number | `computer.uptime()` |

---

## 6. State Cache — Phase 3 Additions

Add **reused** tables (no per-tick allocation):

```lua
-- Written by adapter after stock poll (adapter owns sampling; module owns interpretation)
cache.history = {
  ["Hydrochloric Acid"] = { { t = 100.0, count = 50000 }, ... },  -- ring, max N
}
cache.velocity = {
  ["Hydrochloric Acid"] = -120.5,  -- units per second (negative = draining)
}
cache.ttd = {
  ["Hydrochloric Acid"] = 412.3,   -- seconds; math.huge when not depleting
}
```

**Ring buffer rules:**

- Capacity **N = 60** samples default (≈ 30 s at 0.5 s tick) — matches `me-network-api.md` example.
- Each tick append `{ t = cache.time, count = cache.stock[label] }` only for labels in the **resource_manager input list** (and optionally the process_control product label for output-side trends).
- Drop oldest when `#history > N` (`table.remove(history, 1)`).
- If `stock[label]` is nil, **skip** append (do not insert garbage).

**Velocity calculation** (use oldest vs newest in buffer, not only adjacent ticks — smooths ME lag):

```lua
-- ΔR = (R_new - R_old) / (t_new - t_old)
-- Require dt >= 1.0 s to avoid divide-by-near-zero
-- If ΔR >= 0 → TTD = math.huge (not depleting)
-- Else TTD = current_count / math.abs(ΔR)
```

Expose pure functions in `resource_manager.lua` (or a tiny `lib/ring_buffer.lua` if needed) so `tests/phase3_test.lua` can unit-test math **without** hardware.

---

## 7. New Module — `modules/resource_manager.lua`

### 7.1 Config shape (`ResourceManager.new(config)`)

```lua
{
  inputs = {
    {
      label = "Hydrochloric Acid",  -- ME label (exact); use "drop of X" if discretized fluid
      kind = "item",                  -- "item" | "fluid" — must match adapter target kind
      min = 1000,                   -- soft-sleep when stock < min (immediate missing)
      warn_ttd = 1800,              -- seconds; alert when TTD below this (README default)
      -- optional:
      craft_label = "drop of ...",  -- if different from stock label
    },
  },
  soft_sleep = true,                -- default true: emit P2 pause when input missing
  alert_beep = true,                -- default true on TTD warn (not on every tick — edge-trigger)
}
```

### 7.2 Evaluate logic (priority 2)

For each input, read `cache.stock[label]`, `cache.ttd[label]`, `cache.velocity[label]`:

1. **Missing input:** `stock == nil` or `stock < min` → intent `{ priority = 2, module = "resource_manager", action = "soft_sleep", state = false, reason = "..." }`.
2. **Depletion warning:** `ttd < warn_ttd` and `velocity < 0` → **alert only** (log once on transition; optional short beep). Do **not** soft-sleep unless also below `min` unless config adds `sleep_ttd` threshold later.
3. **Healthy:** return `nil`.

**Soft sleep vs maintenance:**

| | Priority | Action | Beep | Clears when |
|---|----------|--------|------|-------------|
| Maintenance fault | 1 | `force_shutdown` | Yes (800 Hz) | Fault repaired |
| Resource missing | 2 | `soft_sleep` | Optional warn beep | Stock ≥ min |
| Process control | 3 | `set_work_allowed` / craft | No | Hysteresis band |

### 7.3 Intent contract (Priority 2)

```lua
{
  priority = 2,
  module = "resource_manager",
  action = "soft_sleep",       -- new; arbitrator maps to setWorkAllowed(false)
  state = false,               -- always false for soft sleep
  label = "Hydrochloric Acid", -- which input triggered
  stock = 400,                 -- current reading
  min = 1000,
  ttd = 320,                   -- optional telemetry
  reason = "Hydrochloric Acid 400 < min 1000",
}
```

Arbitrator must treat `soft_sleep` like `set_work_allowed(false)` **without** maintenance beep. Use change-only writes (already implemented for work_allowed).

### 7.4 Interaction with process_control (P3)

When P2 wins in a tick:

- P3 `set_work_allowed(true)` and `request_craft` intents are **not committed** (existing `select_intent` picks lowest priority number).
- When input recovers, P2 stops emitting; P3 resumes on next tick — **no latch** in resource_manager unless you add explicit hysteresis on inputs (optional; not required for v1).

**Craft mode note:** Today craft mode keeps machine ON while refilling. Soft sleep should still call `setWorkAllowed(false)` when input missing — ME crafts may fail safely; P2 overrides P3 by design.

**Power loss:** `_power_ok` / `cache.power_loss` already blocks P3 ON and crafts. P2 soft sleep should **also** respect `cache.power_loss` (do not fight GT pause). If emitting soft_sleep during power_loss, prefer **no extra** `setWorkAllowed` writes (already false).

---

## 8. Adapter Changes

1. **Extend `targets` list** in `main.lua`: merge `process_control` target + each `resource_manager.inputs[]` entry (dedupe by label).
2. After `poll_inventory`, call new `Adapter:append_history(cache, labels)`:
   - `labels` = list of label strings to track
   - Reuse `cache.history[label]` tables
3. **Do not** add extra unfiltered ME calls.

Optional (later): throttle input polls every N ticks for huge networks — document in config, default every tick.

---

## 9. Arbitrator Changes

In `Arbitrator:commit`, inside the winning-priority loop:

```lua
elseif intent.action == "soft_sleep" then
  machine_result = self:_commit_work_allowed(false, intent, cache)
```

No beep. Log reason via kernel `log_tick` when committed or on transition.

**Do not** add craft cancellation in Phase 3 v1 — soft sleep stops the machine; ME jobs already throttled in Phase 2.

---

## 10. Kernel / Display / Config

### `main.lua`

```lua
local ResourceManager = require("modules.resource_manager")

-- After maintenance, before process_control:
if deps.resource_manager and self.me then
  self.resource_manager = ResourceManager.new(deps.resource_manager)
  self.modules[#self.modules + 1] = self.resource_manager
end

-- Build adapter targets from process_control + resource_manager inputs (dedupe)
```

Extend `_snapshot` / `_display_key` / `log_tick` with optional `rm` block: worst TTD, soft-sleep reason, input stocks.

**Logging:** Follow existing patterns — transition-only for alerts; silent with display bound unless `verbose=true`.

### `start.lua` example

```lua
resource_manager = me and {
  inputs = {
    { label = "Some Catalyst", kind = "item", min = 64, warn_ttd = 1800 },
  },
} or nil,
```

### `display.lua` (minimal Phase 3)

Add section when snapshot includes resource data:

```
Inputs     HCl stock=400  TTD=320s  (LOW)
```

Full charts remain Phase 4.

---

## 11. Testing — `tests/phase3_test.lua`

Run: `lua tests/phase3_test.lua` (mirror phase1/phase2 harness).

**Required cases:**

| # | Test | Expect |
|---|------|--------|
| 1 | Ring buffer append / cap | 61st sample drops oldest |
| 2 | Velocity positive | ΔR > 0 → TTD = inf |
| 3 | Velocity negative | Known R, ΔR → TTD matches formula |
| 4 | Input below min | P2 intent, `action = soft_sleep` |
| 5 | P2 vs P3 | Low **output** stock wants ON (P3) but missing **input** → OFF committed |
| 6 | P1 vs P2 | Maintenance fault still wins over soft sleep |
| 7 | Alert edge | TTD crosses below 1800 → one log/beep; no spam next ticks |
| 8 | Module contract | `resource_manager.evaluate` makes **zero** ME/gt_machine calls |
| 9 | Adapter contract | One filtered ME read per input label per tick (mock counters) |

Extend `mock_hardware.lua`:

- `set_stock(label, n)` already exists
- Add helper to advance time + drain stock series for velocity tests

**Regression:** Re-run `phase1_test.lua`, `phase2_test.lua`, `display_test.lua` — all must still pass.

---

## 12. Phase 3 Sub-task — `eu_in` Display Fix

**Problem (in-game, documented in `progress.md`):** `getAverageElectricInput()` returns **0** on idle machines even when powered and buffer full. Display shows `eu_in=0` while scanner shows nonzero usage when running.

**Not a control bug** — power gating uses `stored_eu` sensor parse + drained-buffer rule, not `eu_in`.

**Phase 3 display/trends fix (implement in adapter + display, not in process_control gating):**

1. **Parse EU/t from sensor text** when present (GT scanner format varies by machine):
   - Look for lines like `Current Energy Usage:` / next line `144 EU/t` (same two-line pattern as stored energy).
   - Store `cache.eu_input_sensor` and prefer it for **display** when component reads 0 but sensor has a value.
2. **Optional ring buffer** on `eu_input` (component + sensor) for Phase 3/4 trends — rolling average over 10–30 s for display label `eu_in~` without jittering the display refresh key (kernel already excludes raw eu from `_display_key`).
3. **Do not** use smoothed `eu_in` for `power_loss` detection.

**Acceptance:** Panel shows plausible EU/t when machine is actively processing; idle may still read 0 (OK).

Reference: `adapter.lua` functions `parse_eu_pair`, `parse_stored_eu_from_sensor` — copy the two-line pattern.

---

## 13. Priority Matrix (After Phase 3)

```
Priority 1  maintenance      → force_shutdown     → setWorkAllowed(false) + beep
Priority 2  resource_manager → soft_sleep         → setWorkAllowed(false), no beep
Priority 3  process_control  → set_work_allowed   → setWorkAllowed(state)
                              request_craft      → me.request (throttled)
```

Winner = **lowest** priority number among intents emitted that tick. All intents at the **winning** priority level commit (Phase 2 pattern for P3 machine + craft).

---

## 14. In-Game Validation Checklist

After desktop tests pass and files are `wget`'d:

1. **Baseline:** Phase 2 Oxygen line still refills; no duplicate 16000 crafts; maintenance banner still works.
2. **History:** With one configured input, verify `velocity` / `ttd` in verbose log or extended display (not NaN/inf when stock stable).
3. **Soft sleep:** Remove input under `min` → machine pauses; no maintenance beep; panel shows resource reason; restoring input resumes within a few ticks.
4. **P1 override:** Maintenance fault during soft sleep → maintenance still wins.
5. **Power fail:** Disconnect power → `power_loss` blocks ON/craft; resource manager does not spam soft_sleep writes.
6. **eu_in display:** Run recipe → panel shows nonzero EU/t (after §12 fix) while `stored` still parses correctly.

Use `dump.lua` / `me_dump.lua` if labels do not match ME network names.

---

## 15. Known GTNH / GT Quirks (Do Not Re-learn)

| Topic | Behavior | Code location |
|-------|----------|---------------|
| Stored EU | `getStoredEU()` may lie; sensor `Stored Energy:` + next line is truth | `adapter.lua` |
| Power fail | GUI “Shut down due to power loss” often **not** in sensor array | Drained buffer: sensor `0 EU / cap EU` + `eu_in=0` |
| Idle EU in | `getAverageElectricInput()` = 0 idle | Do not gate on eu_in alone |
| Maintenance | `Problems: 0` is healthy; `Problems: N>0` faults | `maintenance.lua` |
| Fluids | ME may use `"drop of Oxygen"` for crafts; stock label may be `"Oxygen"` | `craft_label`, adapter fallback |
| ME lag | Stock updates lag after craft completes | Phase 2 craft cooldown + dispatch grace — keep for Phase 3 |

---

## 16. Implementation Order (Recommended)

1. **`tests/phase3_test.lua` skeleton** — failing tests for ring buffer + TTD math (pure functions).
2. **`modules/resource_manager.lua`** — config, evaluate, alert edge state; no adapter yet (inject fake cache in tests).
3. **`adapter.lua`** — `append_history`, populate `cache.velocity` / `cache.ttd`.
4. **`arbitrator.lua`** — handle `soft_sleep`.
5. **`main.lua`** — wire module, targets merge, logging/snapshot hooks.
6. **`start.lua`** — example config (commented).
7. **Complete tests** — integration cases with mock kernel ticks.
8. **Display** — optional TTD row + §12 eu_in sensor parse.
9. **`progress.md`** append entry; update `references/README.md` index.
10. **In-game validation** — user Oxygen line + one catalyst input.

---

## 17. Acceptance Criteria (Phase 3 Sign-off)

- [ ] `tests/phase3_test.lua` all green; phase1/2/display unchanged green.
- [ ] Resource manager reads **cache only**; adapter remains single ME poll point per label.
- [ ] P2 soft sleep pauses machine when input `< min`; P1 still overrides.
- [ ] TTD alert fires once per threshold crossing (`warn_ttd`, default 1800 s).
- [ ] Tick loop stays ≤ 500 ms on desktop mock with 3 tracked labels.
- [ ] `eu_in` display shows sensor-derived EU/t when running (§12).
- [ ] `progress.md` updated; no contradictions with README architecture.

---

## 18. Phase 4 Handoff (Out of Scope Here)

Phase 4 will consume `cache.history`, `cache.velocity`, and `cache.ttd` for GPU charts (`references/gpu-and-display.md`). Phase 3 must expose stable cache fields and label keys — no GPU code in Phase 3.

---

## 19. Quick Reference — Files to Create/Modify

```
CREATE  modules/resource_manager.lua
CREATE  tests/phase3_test.lua
MODIFY  adapter.lua          -- history + velocity + ttd (+ eu_in sensor parse for §12)
MODIFY  arbitrator.lua       -- soft_sleep commit
MODIFY  main.lua             -- register module, targets, snapshot/log
MODIFY  display.lua          -- optional TTD + eu_in display
MODIFY  start.lua            -- example resource_manager config
MODIFY  tests/mock_hardware.lua
MODIFY  references/README.md -- link this doc
APPEND  progress.md
```

**Do not modify** `modules/process_control.lua` hysteresis rules unless a test proves P2/P3 conflict — prefer arbitration priority instead.
