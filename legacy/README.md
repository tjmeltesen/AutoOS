# AutoOS

A modular, event-driven, universal control system application built in Lua for **OpenComputers** within the **GregTech New Horizons (GTNH)** ecosystem.

AutoOS decouples physical hardware components from high-level logical modules through a centralized broker architecture, ensuring deterministic, optimized, and explosion-proof automated industrial plant management. Inventory leveling uses **ME autocraft recipes** (AE patterns) and/or **gt_machine** run signals — whichever fits the line — all gated by the same hysteresis bands and priority safety tree.

---

## 1. Project Proposal & Vision

Operating a high-tier automated infrastructure in GTNH introduces extreme variables: sudden inventory shortages can stall massive processing chains, unmitigated multiblock maintenance faults corrupt efficiency or trigger total structural collapse, and excessive hardware polling triggers single-threaded OpenComputers "Computer Too Busy" exceptions.

**AutoOS** provides a stable framework to handle these risks. By isolating hardware interactions inside a shared State Cache and running logical actions through a strict, multi-tiered Priority Arbitrator, AutoOS guarantees that hardware safety boundaries are never violated. The system introduces **ME-driven autocraft leveling**, multiblock process control, resource degradation forecasting, and real-time status displays.

---

## 2. System Architecture Layout

The application relies on an isolated, multi-tiered data flow. Modules compute abstract automation intent completely independently, while the **Validation Arbitration Layer** is the exclusive gateway authorized to commit changes to physical blocks and the ME network.

```
[ Hardware / Adapter Layer ] -> Polls gt_machine + ME (stock, craftability). Updates Cache.
              |
              v
[   Central State Cache    ] -> Atomic snapshots: sensor, stock[label], craftable[label].
              |
              v
[ Decoupled Logic Modules  ] -> Hysteresis, maintenance, velocities (cache-only reads).
              |
              v
[   Validation Arbitrator  ] -> Commits setWorkAllowed() + ME craft requests.
```

### Priority Arbitration Matrix

When resource demands conflict with structural safety, the Arbitrator resolves intents based on a rigid tier system:

1. **Priority 1 (Critical Safety):** *Maintenance Module Intercept* — Forces unconditional machine shutdown if errors occur. Overrides all down-line logic commands (including ME crafts).
2. **Priority 2 (Process Integrity):** *Raw Resource Management Intercept* — Suspends lines ("Soft Sleep") if required chemical or material components are missing to prevent empty-cycling.
3. **Priority 3 (Standard Management):** *Multiblock Process Control (MPC)* — Evaluates inventory bands and replenishes stock via **ME autocraft** (`getCraftables` → `request`) and/or **gt_machine** on/off (`setWorkAllowed`).

---

## 3. Strict Functional Requirements & Core Goals

| Domain | Strict Requirement (Functional Contract) | System Metric / Goal |
| :--- | :--- | :--- |
| **Safety / Arbitration** | Maintenance faults must trigger a hard shutdown, overriding all resource-level logic commands. | Zero multiblock damage or processing waste from unmaintained loops. |
| **Stability / Loop Control** | Leveling must utilize dual-threshold hysteresis to eliminate rapid cycling (flapping). | Target buffer maintenance within a static deadband window. |
| **ME Autocraft Leveling** | When stock is low, request AE crafts for the configured `label` up to `high - stock`; throttle while a job is active. | Stock refilled from ME patterns without spamming craft requests every tick. |
| **Compute Optimization** | Hardware components must never be polled directly by modules. All reads draw from the State Cache. | Execution cycle overhead $\le 500\text{ms}$; zero system crashes. |
| **Predictive Alerts** | Provide depletion forecasts using a moving derivative profile: $\Delta R = (R_t - R_{t-\Delta t}) / \Delta t$. | Early warning alarms triggered if Time-to-Depletion ($TTD$) $< 1800\text{s}$. |

---

## 4. Phased Implementation Schedule

To ensure project stability, AutoOS must be developed and verified chronologically in four distinct phases:

### Phase 1: Core Kernel Foundation & Maintenance Safeguards (Module 2) — **complete**

* **Objective:** Establish the main loop, state cache layout, and the underlying priority override tree.
* **Mechanism:** Polls the machine's primary adapter. Parses `getSensorInformation()` for maintenance/structure faults; fires high-priority audio warnings and cuts the run signal via `setWorkAllowed(false)`.

### Phase 2: Multiblock Process Control & Leveling Engine (Module 1) — **implemented**

* **Objective:** Establish automated inventory replenishment control rules.
* **Mechanism:** Dual-limit hysteresis loop on ME stock counts:
  * `STATE_ACTIVE` when stock $< Threshold_{low}$
  * Hold through the deadband until stock $> Threshold_{high}$ (prevents flapping)
* **Replenishment modes** (`process_control.mode` in `start.lua`):
  * `"craft"` — **ME autocraft only.** Issues `getCraftables({label})[1].request(high - stock)` while ACTIVE. Requires a matching AE autocraft pattern in the ME network.
  * `"machine"` — **gt_machine only.** Drives `setWorkAllowed(true/false)` while ACTIVE/IDLE.
  * `"both"` — Machine on **and** ME craft request while refilling.
* **Prerequisites:** ME Interface or Controller adapter; `label` must match the ME display name and an existing autocraft recipe.

### Phase 3: Raw Resource Management & Projection Engine (Module 3)

* **Objective:** Predict bottlenecks before processing blocks stall completely.
* **Mechanism:** Maintains localized ring-buffers tracking inventory counts over time. Computes moving averages of material consumption velocity and calculates Time-to-Depletion warnings.
* **Status:** Implemented (`modules/resource_manager.lua`). The adapter keeps per-input stock history rings and derives `cache.velocity` / `cache.ttd`; the module emits a Priority 2 `soft_sleep` intent (machine OFF, no maintenance beep) while any input sits below its `min` floor, and edge-triggers a depletion warning when TTD drops below `warn_ttd`. Includes the sensor-based `eu_in` display fix. Configure via the commented `resource_manager` block in `start.lua`.
* **Implementation guide:** See [`references/phase3-implementation.md`](references/phase3-implementation.md) for file-by-file steps, intent contracts, tests, and in-game validation (includes deferred `eu_in` display fix).

### Phase 4: Multi-Machine Plant + Display Orchestration (Module 4)

* **Objective:** One OC computer controls **many** multiblock lines; operators manage the plant from an in-game UI.
* **Mechanism (two parts):**
  1. **Multi-machine kernel** — poll each `gt_machine` by stored UUID; nest state in `cache.machines[id]`; scope every intent with `machine_id`; arbitrate Priority 1/2/3 **per line** (electrolyzer soft-sleep must not stop an unrelated tower).
  2. **Display + Add Machine** — multi-page monitor (home, line detail, optional Phase 3 sparklines); wizard to discover a new adapter, apply a template (e.g. Oxygen + Sulfuric Acid), persist to `/home/AutoOS/machines.lua`, and hot-reload without reboot.
* **Shared ME:** One network; stock/history labels deduped across lines. Craft throttle keyed by `machine_id:label`.
* **Status:** Not started — design spec at [`references/phase4-implementation.md`](references/phase4-implementation.md).
* **Note:** Today (Phases 1–3) = **one adapter per computer**. Use separate PCs per multiblock until Phase 4 lands, or one PC with multiple adapters after migration.

---

## 5. In-Game Setup (Process Control + ME Autocraft)

Typical OpenComputers layout on the computer HDD:

```text
/home/
  start.lua
  AutoOS/
    main.lua
    adapter.lua
    arbitrator.lua
    display.lua          # optional read-only status panel
    modules/
      maintenance.lua
      process_control.lua
```

**Hardware:** Adapter on GT controller (`gt_machine`); Adapter on ME Interface/Controller (`me_interface` or `me_controller`); Internet Card for `wget`; optional GPU + Screen for the status panel.

**Configure** the tracked product in `/home/start.lua`:

```lua
process_control = me and {
  label = "Soldering Alloy",   -- exact ME name; must have an AE autocraft recipe
  low = 64000,                 -- enter ACTIVE below this
  high = 142800,               -- leave ACTIVE above this (deadband: low < stock < high)
  kind = "item",               -- "item" or "fluid" (craft mode is item-only)
  mode = "craft",              -- "craft" | "machine" | "both"
} or nil,
```

Verify a recipe exists before booting:

```lua
local c = require("component")
for _, cr in ipairs(c.me_interface.getCraftables({label="Soldering Alloy"})) do
  print("craftable:", cr.label)
end
```

Import/update files via raw GitHub URLs (`wget -f https://raw.githubusercontent.com/<user>/AutoOS/main/...`). See `progress.md` for deployment notes.

---

## 6. Out-of-Game Desktop Testing & Verification Procedure

Testing automation logic inside a live survival world threatens high-tier GTNH machinery. AutoOS logic should be validated entirely off-game using local mock execution files.

### Repository file layout

```text
AutoOS/
├── main.lua
├── adapter.lua
├── arbitrator.lua
├── display.lua
├── modules/
│   ├── process_control.lua
│   ├── maintenance.lua
│   └── resource_manager.lua   # Phase 3 soft sleep + TTD projection
└── tests/
    ├── mock_hardware.lua
    ├── phase1_test.lua
    ├── phase2_test.lua        # hysteresis + ME autocraft
    ├── phase3_test.lua        # ring buffers, TTD, P2 soft sleep
    └── display_test.lua
```

Install a local Lua interpreter (5.2+; project verified on 5.5).

```bash
cd path/to/AutoOS
lua tests/phase1_test.lua   # maintenance + kernel
lua tests/phase2_test.lua   # hysteresis + ME craft modes
lua tests/phase3_test.lua   # resource rings, TTD, P2 soft sleep
lua tests/display_test.lua  # read-only monitor
```

### Desktop verification example (README §5 scenario)

```text
=== Starting AutoOS Desktop Validation Emulator ===
--- SYSTEM TICK 1 ---
[Process Control] Soldering Alloy stock=63000 -> ACTIVE (mode=craft craftable=yes)
[Arbitrator] action: request_craft Soldering Alloy x79800

--- SYSTEM TICK 5 ---
[!] SIMULATOR EVENT: Multiblock broke down with a maintenance fault!
[Maintenance] Fault detected: Machine needs a wrench!
[Arbitrator] action: force_shutdown -> setWorkAllowed(false)
=== Simulation Complete ===
```

Maintenance (Priority 1) overrides ME crafts and machine run signals. ME craft requests are throttled while an `AECraftingJob` is still computing.
