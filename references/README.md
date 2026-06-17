# AutoOS Reference Library

Curated reference for building AutoOS in **OpenComputers** on **GregTech: New Horizons (GTNH)**.

**API stubs** live in [`OC-GTNH-docs-main/`](OC-GTNH-docs-main/) (vendored [OC-GTNH-docs](https://github.com/C0bra5/OC-GTNH-docs) / GTNH-OCLuaDocumentation). AutoOS-specific guides and integration notes remain as markdown in this folder.

## Contents

### AutoOS guides (read these for implementation)

| File | Description |
|------|-------------|
| [autoos-api-mapping.md](autoos-api-mapping.md) | Maps each AutoOS phase/module to the APIs it needs |
| [phase3-implementation.md](phase3-implementation.md) | **Phase 3 build guide** — ring buffers, TTD, soft sleep, tests |
| [phase4-implementation.md](phase4-implementation.md) | **Phase 4 build guide** — multi-machine kernel, Add Machine UI |
| [gtnh-opencomputers-overview.md](gtnh-opencomputers-overview.md) | Adapter/MFU wiring, ME interface vs controller, GTNH patterns |
| [maintenance-and-safety.md](maintenance-and-safety.md) | GT multiblock maintenance faults & AutoOS shutdown logic |
| [gtceu-lcr-gtnh-port-map.md](gtceu-lcr-gtnh-port-map.md) | LCR + GTCEU → AutoOS `lane_dispatch.lua` port map |
| [LCR Universal Automation.lua](LCR%20Universal%20Automation.lua) | Working GTNH OC per-lane transposer reference |
| [cc_gtceu_multipurpose-main/](cc_gtceu_multipurpose-main/) | GTCEU CC round-robin reference (scheduling only) |
| [performance-pitfalls.md](performance-pitfalls.md) | Polling limits, `allItems`, "Computer Too Busy" |
| [external-sources.md](external-sources.md) | Online sources + local doc index |
| [Level-Maintainer-master/](Level-Maintainer-master/) | Companion ME passive autocraft reference |

### OC / GTNH API stubs (`OC-GTNH-docs-main/docs/`)

| Task | Open |
|------|------|
| `component`, proxies, addresses | [`component.lua`](OC-GTNH-docs-main/docs/component.lua) |
| `event`, timers, signals | [`event.lua`](OC-GTNH-docs-main/docs/event.lua) |
| `sides` | [`sides.lua`](OC-GTNH-docs-main/docs/sides.lua) |
| `gt_machine` | [`components/gt_machine.lua`](OC-GTNH-docs-main/docs/components/gt_machine.lua) |
| ME network (shared API) | [`components/abstracts/CommonNetworkAPI.lua`](OC-GTNH-docs-main/docs/components/abstracts/CommonNetworkAPI.lua) |
| ME interface / controller | [`me_interface.lua`](OC-GTNH-docs-main/docs/components/me_interface.lua), [`me_controller.lua`](OC-GTNH-docs-main/docs/components/me_controller.lua) |
| Crafting types | [`type_definitions/ae_types/`](OC-GTNH-docs-main/docs/type_definitions/ae_types/) (`AECraftable`, `AECraftingJob`, `MEItemStack`, …) |
| GPU / screen | [`gpu.lua`](OC-GTNH-docs-main/docs/components/gpu.lua), [`screen.lua`](OC-GTNH-docs-main/docs/components/screen.lua) |
| Modem, redstone, database | [`modem.lua`](OC-GTNH-docs-main/docs/components/modem.lua), [`redstone.lua`](OC-GTNH-docs-main/docs/components/redstone.lua), [`database.lua`](OC-GTNH-docs-main/docs/components/database.lua) |
| Level maintainer, export bus | [`level_maintainer.lua`](OC-GTNH-docs-main/docs/components/level_maintainer.lua), [`me_exportbus.lua`](OC-GTNH-docs-main/docs/components/me_exportbus.lua) |

**Rule:** with multiple adapters, use `component.proxy(address, "gt_machine")` — never rely on `component.gt_machine` primary. See `component.lua` and [phase4-implementation.md](phase4-implementation.md).

## Level-Maintainer — Companion ME Stocking (Simplify AutoOS)

The [`Level-Maintainer-master/`](Level-Maintainer-master/) folder is a vendored copy of [Echoloquate/Level-Maintainer](https://github.com/Echoloquate/Level-Maintainer) (“Infinite Maintainer”). It is **not** part of the AutoOS kernel; it is a reference for offloading ME autocraft so AutoOS can stay focused on multiblock safety and process control.

### What it does

- Runs on its own OpenComputers PC with a full-block ME Interface adapter.
- Loops on a configurable interval (`config.lua` → `cfg.sleep`, default 10s).
- For each configured item/fluid: if stock is below an optional ceiling threshold, issues `getCraftables({label})[1].request(batch_size)`.
- Skips a label when a CPU `finalOutput()` already shows that item crafting (lightweight duplicate guard).
- Caches craftable lookups for 10 minutes (`src/AE2.lua`) to avoid hammering `getCraftables` on large ME networks.
- Supports GTNH fluid drops (`ae2fc:fluid_drop` + registry name) and native fluids via `getFluidInNetwork` (2.9+).

### Where it fits in AutoOS

Use Level-Maintainer as a **separate companion computer** for passive ME stocking. AutoOS on the multiblock controller PC keeps maintenance (P1), soft sleep (P2), and `setWorkAllowed` hysteresis (P3) — without also owning every upstream autocraft recipe.

| Concern | AutoOS (this repo) | Level-Maintainer (companion PC) |
|--------|-------------------|----------------------------------|
| Maintenance shutdown | Yes — `modules/maintenance.lua` | No |
| Input starvation / TTD | Yes — `modules/resource_manager.lua` | No |
| Machine run signal | Yes — `setWorkAllowed` via arbitrator | No |
| ME autocraft for **line output** tied to machine state | Optional — `process_control.mode = "craft"` / `"both"` | No |
| ME autocraft for **bulk inputs / intermediates** | Duplicates arbitrator craft logic per label | Yes — `config.lua` item/fluid table |
| Hysteresis deadband (`low` / `high`) | Yes — prevents flapping on one tracked product | No — fixed `batch_size` per entry |
| Priority arbitration | Yes | No |

**Typical split:** run Level-Maintainer on a small ME-attached PC to keep osmium dust, acid drops, oxygen fluid, etc. topped up; run AutoOS on each multiblock PC with `process_control.mode = "machine"` (or `"both"` only when the AE pattern must execute on *that* machine’s interface). That removes the need to extend `arbitrator.lua` craft throttling and `adapter.lua` `poll_craftables` for every passive buffer item.

### Simplifications enabled

1. **Drop `mode = "craft"` on passive lines** — configure only `low` / `high` + `setWorkAllowed`; let the companion handle ME recipes that feed the network.
2. **Avoid in-world AE Level Maintainer blocks** — same role as OC-driven stocking ([`level_maintainer.lua`](OC-GTNH-docs-main/docs/components/level_maintainer.lua)), but without the lag/randomness called out in the upstream README.
3. **Reduce ME poll load on the controller PC** — craft requests and `getCraftables` caching live on the maintainer; AutoOS adapter keeps a single stock read per tick for the one product the line cares about.
4. **Borrow implementation patterns** — when AutoOS *does* craft in-kernel, `src/AE2.lua` is the reference for per-label craftable cache, CPU `finalOutput()` skip logic, fluid-drop tags, and GTNH 2.9+ `getFluidInNetwork` thresholds (note upstream warning: thresholds on mainnet ME are expensive).

### When to keep craft logic inside AutoOS

Stay with built-in `request_craft` (Phase 2) when:

- The autocraft pattern is bound to the **same** ME interface as the multiblock and must stay synchronized with `setWorkAllowed` (machine off while a job is computing would stall the line).
- You need **hysteresis** on the exact product the multiblock exports (single deadband, not fixed batch loops).
- One computer must arbitrate crafts against maintenance or soft-sleep overrides on the same tick.

See [`Level-Maintainer-master/README.md`](Level-Maintainer-master/README.md) for install (`installer.lua`) and `config.lua` format.

## Quick Start — Discovering Components

```lua
local component = require("component")

for address, ctype in component.list() do
  print(address, ctype)
end

local machine = component.proxy("YOUR-ADDRESS", "gt_machine")
for name, fn in pairs(machine) do
  if type(fn) == "function" then
    print(name, tostring(fn))
  end
end
```

Method signatures: open the matching file under [`OC-GTNH-docs-main/docs/`](OC-GTNH-docs-main/docs/).

## GTNH Fork Note

GTNH ships a **modified** OpenComputers build ([GTNewHorizons/OpenComputers](https://github.com/GTNewHorizons/OpenComputers)). The stubs in `OC-GTNH-docs-main` reflect that fork — GregTech drivers, extended AE2 (fluids, essentia), and GTNH-specific components.
