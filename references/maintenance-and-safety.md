# Multiblock Maintenance & Safety

Sources: [GTNH Multiblock Machines](https://wiki.gtnewhorizons.com/wiki/Multiblock_Machines), [GTNH Open Computers](https://wiki.gtnewhorizons.com/wiki/Open_Computers), [gt_MachineOS](https://github.com/Zeruel13/gt_MachineOS)

## GT Maintenance System

GregTech multiblocks have a **Maintenance Hatch** that tracks up to **6 independent maintenance issues**. Each issue:

- Increases power consumption by **10%**
- All 6 active simultaneously **shuts down** the multiblock
- Displays a specific message on the controller GUI
- Shows **"HAS PROBLEMS"** in WAILA (red text on controller)

### The Six Maintenance Issues

| # | Message | Required Tool |
|---|---------|---------------|
| 1 | Machine needs a hammer! | Hammer |
| 2 | Machine needs a wrench! | Wrench |
| 3 | Machine needs a screwdriver! | Screwdriver |
| 4 | Machine needs some duct tape! | Duct Tape / Soft Mallet |
| 5 | Machine needs a hard hammer! | Hard Hammer |
| 6 | Machine needs a crowbar! | Crowbar |

Repair: open maintenance hatch → pick up tool → click center button (consumes durability/charge).

### Maintenance Hatch Variants

| Hatch | Behavior |
|-------|----------|
| Basic | Manual repair with tools |
| Automatic | Repairs one issue per operation automatically |
| Auto-Taping (UV) | Repairs all issues at no cost (permanent solution) |

Hatches can be **wall-shared** between adjacent multiblocks.

## Detecting Faults via OpenComputers

There is **no dedicated API field** for maintenance status. AutoOS must use:

### Primary: `gt_machine.getSensorInformation()`

Returns `string[]` — same lines as the in-game sensor panel.

```lua
local function strip_format(s)
  return (s:gsub("§.", ""))
end

local MAINTENANCE_PATTERNS = {
  "problem", "maintenance", "repair",
  "needs a hammer", "needs a wrench", "needs a screwdriver",
  "needs some duct tape", "needs a hard hammer", "needs a crowbar",
  "has problems",
}

local function has_maintenance_fault(lines)
  for _, raw in ipairs(lines) do
    local line = strip_format(raw):lower()
    for _, pat in ipairs(MAINTENANCE_PATTERNS) do
      if line:find(pat, 1, true) then
        return true, strip_format(raw)
      end
    end
  end
  return false
end
```

### Secondary Signals

| Check | Method | Indicates |
|-------|--------|-----------|
| Machine disabled | `isWorkAllowed() == false` | May be maintenance OR manual off |
| Not active | `isMachineActive() == false` | Idle or halted |
| Progress stalled | `getWorkProgress()` unchanged + `hasWork()` | Possible fault (not definitive) |

**Do not** use `isWorkAllowed()` alone as maintenance detection — players and other systems also disable machines.

## AutoOS Priority 1 Response

Per README arbitration matrix:

```
IF has_maintenance_fault THEN
  1. setWorkAllowed(false)     -- hard shutdown
  2. computer.beep(800, 2)     -- audio alarm
  3. Display warning on screen
  4. OVERRIDE all lower-priority intents
END
```

```lua
function maintenance.evaluate(cache)
  if cache.has_maintenance_fault then
    return {
      priority = 1,
      machine_id = cache.machine_id,
      action = "force_shutdown",
      reason = cache.fault_message,
    }
  end
end
```

## Power Fail vs Maintenance

Multiblocks also have **power fail** events (insufficient energy). These are distinct from maintenance:

- Power fail: blinking icon, chat message, machine pauses
- Maintenance: WAILA "HAS PROBLEMS", tool-repair messages

Power fail does not require `setWorkAllowed(false)` from AutoOS — the machine self-pauses. Maintenance requires explicit intervention.

## Structural Integrity

Separate from maintenance — multiblock **structure check** failures (broken casings, missing hatches) also halt processing. Sensor lines may include structure error text. Parse for:

- "structure"
- "incomplete"
- "invalid"

Include these in Priority 1 safety shutdown alongside maintenance.

## Repair Automation (Out of AutoOS Scope)

GTNH provides non-OC repair options:

- **Auto Maintenance Hatch** — automatic repair
- **Auto-Taping Maintenance Hatch (UV)** — zero-cost auto repair
- **Drone Downlink Module** — drone-based repair

AutoOS focuses on **detection + shutdown**, not automated repair.

## Formatting Code Cleanup

`sensorInformation` strings frequently contain Minecraft `§` color codes:

```lua
-- § followed by one format character
local clean = raw:gsub("§.", "")
```

Community has requested removal of these codes from the API ([GTNH#9983](https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/issues/9983)) — always strip them in parsers.
