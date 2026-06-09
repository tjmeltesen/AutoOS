# AutoOS

A modular, event-driven, universal control system application built in Lua for **OpenComputers** within the **GregTech New Horizons (GTNH)** ecosystem. 

AutoOS decouples physical hardware components from high-level logical modules through a centralized broker architecture, ensuring deterministic, optimized, and explosion-proof automated industrial plant management.

---

## 1. Project Proposal & Vision

Operating a high-tier automated infrastructure in GTNH introduces extreme variables: sudden inventory shortages can stall massive processing chains, unmitigated multiblock maintenance faults corrupt efficiency or trigger total structural collapse, and excessive hardware polling triggers single-threaded OpenComputers "Computer Too Busy" exceptions.

**AutoOS** provides a stable framework to handle these risks. By isolating hardware interactions inside a shared State Cache and running logical actions through a strict, multi-tiered Priority Arbitrator, AutoOS guarantees that hardware safety boundaries are never violated. The system introduces process control leveling, resource degradation forecasting, and real-time visualization matrices.

---

## 2. System Architecture Layout

The application relies on an isolated, multi-tiered data flow. Modules compute abstract automation intent completely independently, while the **Validation Arbitration Layer** serves as the exclusive gateway authorized to commit changes to physical blocks.

[ Hardware / Adapter Layer ] -> Pulls data from ME Networks / GT Adapters. Updates Cache.
│
▼
[   Central State Cache    ] -> Holds atomic snapshots of item deltas & error frames.
│
▼
[ Decoupled Logic Modules  ] -> Processes MPC loops, maintenance states, & velocities.
│
▼
[   Validation Arbitrator  ] -> Enforces priority matrices and flattens outputs.


### Priority Arbitration Matrix
When resource demands conflict with structural safety, the Arbitrator resolves intents based on a rigid tier system:
1. **Priority 1 (Critical Safety):** *Maintenance Module Intercept* — Forces unconditional machine shutdown if errors occur. Overrides all down-line logic commands.
2. **Priority 2 (Process Integrity):** *Raw Resource Management Intercept* — Suspends lines ("Soft Sleep") if required chemical or material components are missing to prevent empty-cycling.
3. **Priority 3 (Standard Management):** *Multiblock Process Control (MPC)* — Evaluates inventory bands and cycles machines to fulfill standard stock levels.

---

## 3. Strict Functional Requirements & Core Goals

| Domain | Strict Requirement (Functional Contract) | System Metric / Goal |
| :--- | :--- | :--- |
| **Safety / Arbitration** | Maintenance faults must trigger a hard shutdown, overriding all resource-level logic commands. | Zero multiblock damage or processing waste from unmaintained loops. |
| **Stability / Loop Control** | Leveling must utilize dual-threshold hysteresis to eliminate machine rapid cycling (flapping). | Target buffer maintenance within a static deadband window. |
| **Compute Optimization** | Hardware components must never be polled directly by modules. All reads draw from the State Cache. | Execution cycle overhead $\le 500\text{ms}$; zero system crashes. |
| **Predictive Alerts** | Provide depletion forecasts using a moving derivative profile: $\Delta R = (R_t - R_{t-\Delta t}) / \Delta t$. | Early warning alarms triggered if Time-to-Depletion ($TTD$) $< 1800\text{s}$. |

---

## 4. Phased Implementation Schedule

To ensure project stability, AutoOS must be developed and verified chronologically in four distinct phases:

### Phase 1: Core Kernel Foundation & Maintenance Safeguards (Module 2)
* **Objective:** Establish the main loop, state cache layout, and the underlying priority override tree.
* **Mechanism:** Polls the machine's primary adapter. If `has_maintenance_fault == true`, fires high-priority visual/audio warnings and cuts the active run signal to the machine.

### Phase 2: Multiblock Process Control & Leveling Engine (Module 1)
* **Objective:** Establish automated inventory replenishment control rules.
* **Mechanism:** Implements a dual-limit hysteresis loop. The target line enters `STATE_ACTIVE` when stock drops below $Threshold_{low}$, and runs continuously until it fulfills stock past $Threshold_{high}$ to prevent system flapping.

### Phase 3: Raw Resource Management & Projection Engine (Module 3)
* **Objective:** Predict bottlenecks before processing blocks stall completely.
* **Mechanism:** Maintains localized ring-buffers tracking inventory counts over time. Computes moving averages of material consumption velocity and calculates Time-to-Depletion warnings.

### Phase 4: Time-Varying Charts & Display Orchestration (Module 4)
* **Objective:** High-fidelity monitoring UI.
* **Mechanism:** Pulls data history vectors from Phase 3's buffers and maps them to text layouts or pseudo-braille graphics using raw OpenComputers GPU buffer components at a throttled frame-tick.

---

## 5. Out-of-Game Desktop Testing & Verification Procedure

Testing automation logic inside a live survival world threatens high-tier GTNH machinery. AutoOS logic should be validated entirely off-game using local mock execution files.

### Repository Setup Profile
Maintain the following file topology in your desktop directory:
```text
AutoOS/
├── main.lua          # Core execution state loop
├── arbitrator.lua    # The validation safety layer
├── modules/
│   ├── process_control.lua
│   ├── maintenance.lua
│   └── resource_manager.lua
└── tests/
    └── mock_hardware.lua   # Injects fake OpenComputers components & ticks



Desktop Execution Verification Example
Install a local Lua interpreter environment matching version 5.2 or 5.3.

Open your terminal emulator, navigate to the AutoOS directory, and verify processing pipelines:

$ cd path/to/AutoOS
$ lua main.lua

=== Starting AutoOS Desktop Validation Emulator ===
--- SYSTEM TICK 1 ---
[Module 1] Requested Machine State: true
[Hardware Output] Machine 'mb_01_platinum_line' set to ACTIVE = true
[Data Tracker] Soldering Alloy Volume: 142800 L

--- SYSTEM TICK 5 ---
[!] SIMULATOR EVENT: Multiblock broke down with a maintenance fault!
[Module 1] Requested Machine State: true
[Hardware Output] Machine 'mb_01_platinum_line' set to ACTIVE = false
[Data Tracker] Soldering Alloy Volume: 142800 L
=== Simulation Complete ===