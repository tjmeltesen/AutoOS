# gt_machine Component API

Source: [GTNH-OC-Lua-Documentation — gt-machine.lua](https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/gt-machine.lua), [GTNH Wiki](https://wiki.gtnewhorizons.com/wiki/Open_Computers)

Component type: `gt_machine`  
Exposed by: **Adapter** on GregTech machine controller (or MFU-linked adapter)

## Access Pattern

```lua
local component = require("component")
local machine = component.proxy("YOUR-ADDRESS-HERE", "gt_machine")

-- Or pin primary (not recommended for production)
local machine = component.gt_machine
```

## Full Method Reference

### Identity & Location

| Method | Returns | Description |
|--------|---------|-------------|
| `getName()` | string | Machine display name |
| `getOwnerName()` | string | Block owner |
| `getCoordinates()` | {x, y, z} | World position |

### Run Control (Critical for AutoOS)

| Method | Returns | Description |
|--------|---------|-------------|
| `isWorkAllowed()` | boolean | Whether machine is permitted to run |
| `setWorkAllowed(enabled)` | number | Enable/disable machine; returns `packetPerTick` |
| `isMachineActive()` | boolean | Currently processing |
| `hasWork()` | boolean | Has pending work/recipe |

**AutoOS arbitrator uses `setWorkAllowed()` as the sole run-signal commit.**

### Progress

| Method | Returns | Description |
|--------|---------|-------------|
| `getWorkProgress()` | number | Current progress in ticks |
| `getWorkMaxProgress()` | number | Max progress in ticks |

### Sensor Information (Maintenance & Status)

| Method | Returns | Description |
|--------|---------|-------------|
| `getSensorInformation()` | string[] | Lines shown in machine sensor panel |

Returns an array of display strings (same text as in-game sensor card). **This is the primary maintenance data source.**

Known issues:
- Strings may contain Minecraft formatting codes (`§` color codes) — strip before parsing
- Some machines (e.g. LSC) have had overflow bugs returning garbage values
- No structured boolean for "has maintenance fault" — must parse text

**Example parser for maintenance detection:**

```lua
local function has_maintenance_fault(sensor_lines)
  for _, line in ipairs(sensor_lines) do
    local clean = line:gsub("§.", "")  -- strip color codes
    local lower = clean:lower()
    if lower:find("problem") or lower:find("maintenance") or lower:find("repair") then
      return true, clean
    end
  end
  return false
end

local lines = machine.getSensorInformation()
local fault, msg = has_maintenance_fault(lines)
```

WAILA shows **"HAS PROBLEMS"** on the controller when maintenance issues exist. Sensor lines typically mirror this.

### Energy (EU)

| Method | Returns | Description |
|--------|---------|-------------|
| `getStoredEU()` | number | EU stored |
| `getStoredEUString()` | string | EU stored (string for huge values) |
| `getEUCapacity()` | number | Max EU capacity |
| `getEUCapacityString()` | string | Max EU as string |
| `getEUMaxStored()` | number | Max storable EU |
| `getEUInputAverage()` | number | Avg EU input |
| `getEUOutputAverage()` | number | Avg EU output |
| `getAverageElectricInput()` | number | Avg EU accepted (last 5 ticks) |
| `getAverageElectricOutput()` | number | Avg EU output (last 5 ticks) |
| `getInputVoltage()` | number | Max input EU/p |
| `getOutputVoltage()` | number | Output EU/p |
| `getOutputAmperage()` | number | Energy packets per tick |

### Steam

| Method | Returns | Description |
|--------|---------|-------------|
| `getSteamStored()` | number | Steam stored |
| `getStoredSteam()` | number | Steam as EU units |
| `getSteamCapacity()` | number | Steam capacity as EU |
| `getSteamMaxStored()` | number | Max steam |

## AutoOS Phase 1 Example

```lua
local cache = {}

function poll_gt_machine(machine)
  cache.sensor = machine.getSensorInformation()
  cache.work_allowed = machine.isWorkAllowed()
  cache.active = machine.isMachineActive()
  cache.progress = machine.getWorkProgress()
  cache.max_progress = machine.getWorkMaxProgress()

  local fault = false
  for _, line in ipairs(cache.sensor) do
    if line:gsub("§.", ""):lower():find("problem") then
      fault = true
      break
    end
  end
  cache.has_maintenance_fault = fault
end

function maintenance_module_intent(cache)
  if cache.has_maintenance_fault then
    return { priority = 1, action = "shutdown", reason = "maintenance" }
  end
end

function arbitrator_commit(machine, intent)
  if intent.action == "shutdown" then
    machine.setWorkAllowed(false)
    computer.beep(800, 1)
  end
end
```

## GT Controller GUI Controls (In-Game Reference)

From [GTNH Multiblock Machines wiki](https://wiki.gtnewhorizons.com/wiki/Multiblock_Machines):

| Tool | Action on Controller |
|------|---------------------|
| Soft Mallet | Enable/disable machine (same as `setWorkAllowed`) |
| Screwdriver | Toggle input separation |
| Wire Cutters | Toggle batch mode |
| Wrench | Rotate structure |

`setWorkAllowed(false)` mirrors disabling via Soft Mallet or the GUI power switch.
