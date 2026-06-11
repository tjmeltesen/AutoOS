# AutoOS → API Mapping

How each AutoOS module maps to OpenComputers / GTNH APIs.

**Method signatures:** [`OC-GTNH-docs-main/docs/`](OC-GTNH-docs-main/docs/) — see [`references/README.md`](README.md) for the file index.

## Architecture Layers

```
[ Hardware / Adapter Layer ]  →  component.proxy(), gt_machine, me_interface
[   Central State Cache    ]  →  Lua tables; no direct hardware calls
[ Decoupled Logic Modules  ]  →  Pure Lua; reads cache only
[   Validation Arbitrator  ]  →  setWorkAllowed(), redstone, beep()
```

## Phase 1 — Core Kernel & Maintenance (Module 2)

| AutoOS Need | API | Key Methods |
|-------------|-----|-------------|
| Poll machine adapter | `gt_machine` | `getSensorInformation()`, `isMachineActive()`, `isWorkAllowed()` |
| Detect maintenance fault | `gt_machine` | Parse `getSensorInformation()` for problem strings |
| Hard shutdown on fault | `gt_machine` | `setWorkAllowed(false)` |
| Audio/visual alarm | `computer` | `computer.beep(frequency, duration)` |
| Display warnings | `term` / `gpu` | `term.write()`, `gpu.set()` |

**Maintenance detection:** There is no dedicated `has_maintenance_fault` boolean. Parse the string array from `getSensorInformation()` for maintenance-related lines (e.g. "Problems", "HAS PROBLEMS", tool-repair messages). See [maintenance-and-safety.md](maintenance-and-safety.md).

## Phase 2 — Multiblock Process Control (Module 1)

| AutoOS Need | API | Key Methods |
|-------------|-----|-------------|
| Read inventory levels | `me_controller` / `me_interface` | `getItemsInNetwork(filter)`, `getFluidsInNetwork()` |
| Hysteresis on/off control | `gt_machine` | `setWorkAllowed(true/false)`, `isWorkAllowed()` |
| Machine active state | `gt_machine` | `isMachineActive()`, `hasWork()` |
| Progress tracking | `gt_machine` | `getWorkProgress()`, `getWorkMaxProgress()` |

**Hysteresis pattern:**
- `STATE_ACTIVE` when stock < `Threshold_low`
- Run until stock > `Threshold_high`
- Use `setWorkAllowed()` as the run signal, not redstone (unless wired externally)

## Phase 3 — Raw Resource Management (Module 3)

| AutoOS Need | API | Key Methods |
|-------------|-----|-------------|
| Inventory snapshots | `me_interface` | `getItemsInNetwork({label="..."})`, `getFluidsInNetwork()` |
| Consumption velocity | Lua math | Ring buffer + `ΔR = (R_t - R_{t-Δt}) / Δt` |
| Time-to-depletion | Lua math | `TTD = current_amount / abs(ΔR)` when ΔR < 0 |
| Crafting requests | `me_interface` | `getCraftables(filter)` → `.request(amount)` |
| Craft job status | `AECraftingJob` | `isDone()`, `hasFailed()`, `isComputing()` |

**Filter example for a specific fluid drop:**
```lua
local items = me.getItemsInNetwork({label = "drop of Hydrochloric Acid"})
local count = items[1] and items[1].size or 0
```

## Phase 4 — Charts & Display (Module 4)

| AutoOS Need | API | Key Methods |
|-------------|-----|-------------|
| Bind display | `gpu` | `gpu.bind(screenAddress)` |
| Resolution | `gpu` | `setResolution(w, h)`, `getSize()` |
| Text layout | `term` / `gpu` | `term.write()`, `gpu.set(x, y, char)` |
| Off-screen buffers | `gpu` | `allocateBuffer()`, `bitblt()`, `setActiveBuffer()` |
| Throttled refresh | `event` | `event.timer(interval, callback)` |
| Pseudo-braille charts | `gpu` | `fill()`, `copy()`, palette colors |

## Priority Arbitration Matrix

| Priority | Module | Override Action | API Call |
|----------|--------|-----------------|----------|
| 1 — Critical Safety | Maintenance | Force shutdown | `gt_machine.setWorkAllowed(false)` |
| 2 — Process Integrity | Resource Manager | Soft sleep | `gt_machine.setWorkAllowed(false)` |
| 3 — Standard | Process Control | Normal on/off | `gt_machine.setWorkAllowed(state)` |

The arbitrator is the **only** layer that calls `setWorkAllowed()`. All modules emit intent; the arbitrator commits.

## Desktop Mock Testing

For off-game validation (README §5), mock these interfaces in `tests/mock_hardware.lua`:

```lua
-- Minimum mock surface
mock_gt_machine = {
  getSensorInformation = function() return {"Idle", "No problems"} end,
  isWorkAllowed = function() return true end,
  setWorkAllowed = function(v) mock_state.active = v end,
  isMachineActive = function() return mock_state.active end,
}
mock_me = {
  getItemsInNetwork = function() return {{label="Soldering Alloy", size=142800}} end,
  getFluidsInNetwork = function() return {} end,
}
```
