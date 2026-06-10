# AutoOS Reference Library

Curated API and integration reference for building AutoOS in **OpenComputers** on **GregTech: New Horizons (GTNH)**.

These notes are compiled from official OpenComputers documentation, the GTNH wiki, and the community [GTNH-OC-Lua-Documentation](https://github.com/Navatusein/GTNH-OC-Lua-Documentation) project (which documents the GTNH fork of OpenComputers).

## Contents

| File | Description |
|------|-------------|
| [autoos-api-mapping.md](autoos-api-mapping.md) | Maps each AutoOS phase/module to the APIs it needs |
| [phase3-implementation.md](phase3-implementation.md) | **Phase 3 build guide** — ring buffers, TTD, soft sleep, tests, constraints |
| [opencomputers-component-api.md](opencomputers-component-api.md) | Core `component` library: proxies, addresses, primaries |
| [opencomputers-libraries.md](opencomputers-libraries.md) | `computer`, `event`, `term`, `sides`, signals |
| [gtnh-opencomputers-overview.md](gtnh-opencomputers-overview.md) | GTNH adapter setup, MFU, discovery patterns |
| [gt-machine-api.md](gt-machine-api.md) | `gt_machine` component — multiblock control & sensors |
| [me-network-api.md](me-network-api.md) | AE2 / ME network APIs (`me_controller`, `me_interface`) |
| [gpu-and-display.md](gpu-and-display.md) | GPU, screen, term APIs for monitoring UI (Phase 4) |
| [supporting-components.md](supporting-components.md) | redstone, modem, database, transposer, level_maintainer |
| [maintenance-and-safety.md](maintenance-and-safety.md) | GT multiblock maintenance faults & shutdown logic |
| [performance-pitfalls.md](performance-pitfalls.md) | Polling limits, `allItems`, "Computer Too Busy" |
| [external-sources.md](external-sources.md) | Full list of online sources used to build this library |

## Quick Start — Discovering Components

```lua
local component = require("component")

-- List all connected components
for address, ctype in component.list() do
  print(address, ctype)
end

-- Inspect methods on a specific component type
local machine = component.gt_machine
for name, fn in pairs(machine) do
  if type(fn) == "function" then
    print(name, tostring(fn))  -- tostring(fn) returns doc string
  end
end
```

## GTNH Fork Note

GTNH ships a **modified** OpenComputers build ([GTNewHorizons/OpenComputers](https://github.com/GTNewHorizons/OpenComputers)). APIs documented here reflect that fork, which adds GregTech device drivers, extended AE2 integration (fluids, essentia), and GTNH-specific components.
