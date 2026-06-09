# External Sources

All online references used to compile this library.

## Official OpenComputers Documentation

| Resource | URL |
|----------|-----|
| OpenComputers Doc Home | https://ocdoc.cil.li/ |
| Component API | https://ocdoc.cil.li/api:component |
| Component Access | https://ocdoc.cil.li/component:component_access |
| Computer API | https://ocdoc.cil.li/api:computer |
| Event API | https://ocdoc.cil.li/api:event |
| Term API | https://ocdoc.cil.li/api:term |
| Sides API | https://ocdoc.cil.li/api:sides |
| Signals | https://ocdoc.cil.li/component:signals |
| GPU Component | https://ocdoc.cil.li/component:gpu |
| Screen Component | https://ocdoc.cil.li/component:screen |
| Modem Component | http://ocdoc.cil.li/component:modem |
| GitHub Wiki | https://github.com/MightyPirates/OpenComputers/wiki |

## GTNH Wiki

| Resource | URL |
|----------|-----|
| Open Computers | https://wiki.gtnewhorizons.com/wiki/Open_Computers |
| Multiblock Machines | https://wiki.gtnewhorizons.com/wiki/Multiblock_Machines |

## GTNH OpenComputers Fork

| Resource | URL |
|----------|-----|
| GTNewHorizons/OpenComputers | https://github.com/GTNewHorizons/OpenComputers |
| Capability PR (GT device info) | https://github.com/GTNewHorizons/OpenComputers/pull/151 |
| AE2 StackApi integration PR | https://github.com/GTNewHorizons/OpenComputers/pull/169 |

## Community Documentation & Tools

| Resource | URL | Notes |
|----------|-----|-------|
| GTNH-OC-Lua-Documentation | https://github.com/Navatusein/GTNH-OC-Lua-Documentation | VS Code Lua stubs; primary source for method signatures |
| gt_MachineOS | https://github.com/Zeruel13/gt_MachineOS | Reference implementation for multiblock monitoring |
| opencomputer-monitor | https://github.com/52871299hzy/opencomputer-monitor | Web monitor for GT + AE |

### Key Files from GTNH-OC-Lua-Documentation

| File | URL |
|------|-----|
| component.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/libs/component.lua |
| computer.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/libs/computer.lua |
| event.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/libs/event.lua |
| gt-machine.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/gt-machine.lua |
| common-network-api.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/abstracts/common-network-api.lua |
| me-interface.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/me-interface.lua |
| me-exportbus.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/me-exportbus.lua |
| gpu.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/gpu.lua |
| redstone.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/redstone.lua |
| modem.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/modem.lua |
| database.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/database.lua |
| transposer.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/transposer.lua |
| level-maintainer.lua | https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/level-maintainer.lua |

## Known Issues & Bug Reports

| Issue | URL | Relevance |
|-------|-----|-----------|
| LSC sensor overflow / § codes | https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/issues/9983 | `getSensorInformation()` parsing |
| `allItems()` ME crash | https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/issues/19874 | Avoid in production loops |

## In-Game Discovery Commands

Run on an OC computer to introspect live components:

```lua
local component = require("component")
for k,v in component.list() do print(k,v) end

local m = component.gt_machine
for k,v in pairs(m) do print(k, tostring(v)) end
```

Use the **Analyzer** (Ctrl+right-click) to copy component addresses from blocks.
