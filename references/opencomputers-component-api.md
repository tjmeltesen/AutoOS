# OpenComputers — Component API

Source: [ocdoc.cil.li — Component API](https://ocdoc.cil.li/api:component), [Component Access](https://ocdoc.cil.li/component:component_access)

## Overview

Components are blocks or items that expose a Lua API to connected computers. Every component has a unique **address** (UUID) and a **type** string (e.g. `gpu`, `gt_machine`, `me_interface`).

## Loading the Library

```lua
local component = require("component")
```

## Listing Components

```lua
-- All components: returns iterator of address, type
for address, ctype in component.list() do
  print(address, ctype)
end

-- Filter by partial type name
for address, ctype in component.list("me_", false) do
  print(address, ctype)
end

-- Exact type match
for address, ctype in component.list("gt_machine", true) do
  print(address, ctype)
end
```

## Proxies (Preferred Access Pattern)

A proxy wraps a component address as a table of callable methods:

```lua
local addr = component.list("gt_machine")()  -- first gt_machine address
local machine = component.proxy(addr)

machine.setWorkAllowed(false)
print(machine.address)  -- component UUID
print(machine.type)     -- "gt_machine"
```

## Primary Components

When multiple components share a type, one is designated "primary" (selection is arbitrary):

```lua
component.gpu           -- shorthand for component.getPrimary("gpu")
component.getPrimary("gpu")
component.isAvailable("gpu")  -- check before getPrimary
component.setPrimary("gpu", address)  -- pin a specific instance
```

**AutoOS rule:** Never rely on primaries for production machines. Always resolve by stored address.

## Core Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `list` | `list([filter, exact]) → iterator` | Iterate `address, type` pairs |
| `proxy` | `proxy(address) → table` | Get callable proxy |
| `invoke` | `invoke(address, method, ...) → ...` | Low-level method call |
| `methods` | `methods(address) → table` | List method names for a component |
| `doc` | `doc(address, method) → string` | Method documentation string |
| `get` | `get(address[, type]) → string\|nil` | Resolve abbreviated address |
| `type` | `type(address) → string` | Get component type from address |
| `slot` | `slot(address) → integer` | Slot index if item component, else -1 |
| `isAvailable` | `isAvailable(type) → boolean` | Check if type exists |
| `getPrimary` | `getPrimary(type) → table` | Get primary proxy (throws if missing) |
| `setPrimary` | `setPrimary(type, address\|nil)` | Set primary; fires signals |

## Getting Addresses In-Game

1. Hold **Ctrl** and right-click a block with the **Analyzer**
2. Paste the address into your script config
3. Use `component.get("abc")` for abbreviated lookup

## Direct vs. Delegated Calls

- **Normal calls** are delegated to the server thread (~1 tick / 50ms latency)
- **Direct calls** run in the computer worker thread (instant return)
- Check `component.methods(address)` — values indicate direct-call capability

## Signals on Component Change

| Signal | When |
|--------|------|
| `component_available(type)` | Primary component added/changed |
| `component_unavailable(type)` | Primary component removed |

Prefer these over raw `component_added` / `component_removed`.

## GTNH-Registered Component Types (Partial)

From [GTNH-OC-Lua-Documentation](https://github.com/Navatusein/GTNH-OC-Lua-Documentation):

| Type | Source |
|------|--------|
| `gt_machine` | GregTech multiblock / device via Adapter |
| `me_controller` | AE2 ME Controller via Adapter |
| `me_interface` | AE2 ME Interface via Adapter |
| `me_exportbus` | AE2 Export Bus via Adapter |
| `level_maintainer` | AE2 Level Maintainer via Adapter |
| `database` | OC Database block |
| `transposer` | OC Transposer block |
| `redstone` | Redstone Card / I/O block |
| `modem` | Network Card |
| `gpu` | Graphics Card |
| `screen` | Screen block |
| `tps_card` | GTNH TPS Card |
