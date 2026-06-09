# GTNH — OpenComputers Integration Overview

Sources: [GTNH Wiki — Open Computers](https://wiki.gtnewhorizons.com/wiki/Open_Computers), [GTNewHorizons/OpenComputers](https://github.com/GTNewHorizons/OpenComputers)

## What GTNH Adds

GTNH ships a fork of OpenComputers with integrated mod drivers (formerly OpenComponents). Key integrations for AutoOS:

- **GregTech devices** → `gt_machine` component
- **Applied Energistics 2** → `me_controller`, `me_interface`, `me_exportbus`, `level_maintainer`
- Extended AE2: fluids, essentia, power metrics, `allItems()` iterator
- **GT energy containers** via capability interface (`IBasicEnergyContainer`, `IGregTechDeviceInformation`)

## Connecting to Hardware

### Adapter Block

Place an **Adapter** adjacent to the target block's controller. The adapter exposes the block as an OC component.

```
[Computer]──[Cable]──[Adapter]──[GT Controller]
                         or
[Computer]──[Cable]──[Adapter]──[ME Interface]
```

### MFU (Machine Frequency Upgrade) — Wireless Link

For machines more than 1 block away:

1. Sneak right-click the controller with an **MFU**
2. Insert the MFU into an Adapter within **16 blocks**
3. The adapter wirelessly links to the machine

Used heavily in GTNH for large multiblock layouts.

## Discovering Components

```lua
local component = require("component")

-- Step 1: Find component type name
for k, v in component.list() do print(k, v) end
-- Expect: gt_machine, me_interface, me_controller, etc.

-- Step 2: List all methods
local machine = component.gt_machine
for k, v in pairs(machine) do print(k, v) end
```

## Component Type Reference

| Type | Block | Use in AutoOS |
|------|-------|---------------|
| `gt_machine` | GT controller / tank / generator | Maintenance, run control, progress |
| `me_interface` | ME Interface (+ Adapter) | Inventory read, crafting, stocking |
| `me_controller` | ME Controller (+ Adapter) | Read-only network queries |
| `me_exportbus` | ME Export Bus (+ Adapter) | Targeted item export |
| `level_maintainer` | Level Maintainer (+ Adapter) | AE auto-stock (alternative to OC logic) |
| `database` | OC Database | Item descriptors for ME config |
| `transposer` | OC Transposer | Physical item/fluid transfer |
| `redstone` | Redstone Card / I/O | External redstone control |
| `tps_card` | TPS Card (GTNH) | Server performance monitoring |

## ME Interface vs ME Controller

**Prefer `me_interface`** for AutoOS — it includes all ME Controller methods plus:

- Interface stocking configuration
- Pattern input/output management
- Crafting via `getCraftables()` → `.request()`

Connect the adapter to an ME Interface that has network access (channel or ad-hoc).

## Power

OpenComputers computers consume energy while running. Component workload adds cost:

- GPU screen updates consume extra energy per changed cell
- Wireless modem messages cost more at higher signal strength
- Frequent `getItemsInNetwork()` on large ME networks is CPU-expensive on the OC thread

GTNH power equivalents: EU from GregTech energy network via power converter / capacitor.

## Meta-Automation Patterns (GTNH Wiki)

Documented GTNH use cases enabled by OC + AE:

- Level maintenance via OC instead of Level Maintainer blocks
- Automated Magmatter / Degenerate Quark Gluon Plasma lines
- Pattern stocking via `setInterfacePatternInput/Output` + craft requests

## Related Community Projects

| Project | Purpose |
|---------|---------|
| [gt_MachineOS](https://github.com/Zeruel13/gt_MachineOS) | Multiblock monitor UI; maintenance alerts; `setWorkAllowed` toggle |
| [GTNH-OC-Lua-Documentation](https://github.com/Navatusein/GTNH-OC-Lua-Documentation) | VS Code Lua stubs for autocomplete |
| [opencomputer-monitor](https://github.com/52871299hzy/opencomputer-monitor) | Web dashboard for GT machines + AE |
