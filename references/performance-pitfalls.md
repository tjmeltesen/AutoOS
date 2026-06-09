# Performance Pitfalls & Compute Optimization

Sources: AutoOS README, [GTNH OC Wiki](https://wiki.gtnewhorizons.com/wiki/Open_Computers), [GTNH#19874 allItems crash](https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/issues/19874)

## The "Computer Too Busy" Problem

OpenComputers runs Lua on a **single worker thread** per computer. If a tick takes too long:

- The computer throws **"Computer Too Busy"**
- The program may crash or hang
- Repeated crashes can destabilize the OC network

**AutoOS target:** execution cycle overhead ≤ **500ms** per tick.

## Root Causes in GTNH Automation

| Cause | Why It Hurts |
|-------|-------------|
| Direct module polling | Each `getItemsInNetwork()` crosses thread boundary (~50ms) |
| Large ME networks | Thousands of item types = huge table allocation |
| `allItems()` in tight loops | Iterator + network mutation = crash risk |
| GPU full-screen refresh | Every cell change costs energy + time |
| Uncoordinated timers | Multiple `event.timer` callbacks stacking |

## AutoOS Mitigation Rules

### 1. State Cache — Single Poll Point

```
WRONG:  each module calls me.getItemsInNetwork()
RIGHT:  adapter layer polls once → cache → modules read cache
```

```lua
-- adapter.lua — only place that touches hardware
function Adapter.tick()
  cache.gt = poll_gt(machine)
  cache.me = poll_me(me)       -- ONE call per tick
  cache.time = computer.uptime()
end

-- modules read cache only
function ProcessControl.evaluate(cache)
  local count = cache.me.items["Soldering Alloy"] or 0
end
```

### 2. Throttle ME Queries

| Network Size | Suggested Interval |
|-------------|-------------------|
| Small (<500 types) | Every tick (0.5s) |
| Medium (500-2000) | Every 2-5 seconds |
| Large (2000+) | Every 10-30 seconds |

Use filtered queries when possible:

```lua
-- GOOD: targeted
me.getItemsInNetwork({ label = "Soldering Alloy" })

-- BAD: full network scan every tick
me.getItemsInNetwork()
```

### 3. Avoid `allItems()` in Production

`allItems()` returns a lazy iterator but has known issues in GTNH:

- Can crash server when items cycle in/out of ME network
- Problematic with export buses, level maintainers, stocking interfaces
- [GTNH#19874](https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/issues/19874)

**Prefer `getItemsInNetwork(filter)` with specific filters.**

### 4. Batch GPU Updates

```lua
-- Draw to off-screen buffer, blit once
gpu.setActiveBuffer(buf)
draw_chart(data)
gpu.setActiveBuffer(0)
gpu.bitblt(0, 1, 1, w, h, buf, 1, 1)
```

Avoid `gpu.set()` per data point on the visible screen.

### 5. Main Loop Timing

```lua
local TICK = 0.5
while true do
  local t0 = computer.uptime()
  Adapter.tick()
  local intents = Modules.collect(cache)
  Arbitrator.commit(intents)
  local elapsed = computer.uptime() - t0
  local sleep = math.max(0, TICK - elapsed)
  if sleep > 0 then event.pull(sleep) end
end
```

Log `elapsed` during development; alert if consistently > 0.4s.

### 6. Component Call Budget

Approximate per-tick budget for a 500ms target:

| Operation | Est. Cost | Max/Tick |
|-----------|-----------|----------|
| `gt_machine.getSensorInformation()` | ~50ms | 1-2 machines |
| `getItemsInNetwork(filter)` | 50-200ms | 1-3 queries |
| `setWorkAllowed()` | ~50ms | 1 per machine |
| `gpu.fill()` large area | 10-50ms | 1-2 |
| `computer.beep()` | <5ms | occasional |

With 3 multiblocks + 1 ME query, expect ~200-350ms. Stay within budget.

## Memory

```lua
computer.freeMemory()  -- monitor during development
```

OpenOS needs ≥1x Tier 1.5 RAM. Large item tables from ME queries consume heap — reuse cache tables instead of allocating new ones each tick:

```lua
-- Reuse table
for k in pairs(cache.items) do cache.items[k] = nil end
for _, stack in ipairs(me_result) do
  cache.items[stack.label] = stack.size
end
```

## Direct Calls

Some component methods support **direct calls** (instant, no server thread hop). Check:

```lua
for name, direct in pairs(component.methods(addr)) do
  if direct then print("DIRECT:", name) end
end
```

Use direct-call methods for hot paths when available.

## Monitoring Server Health

GTNH **TPS Card** component can read server TPS from OC. Low TPS increases OC call latency. Consider backing off poll rates when TPS < 18.

## Desktop Testing Alignment

The README's mock emulator should simulate timing constraints:

```lua
-- mock_hardware.lua
function mock_me.getItemsInNetwork()
  mock_stats.me_calls = mock_stats.me_calls + 1
  return mock_data.items
end

-- Assert in tests:
assert(mock_stats.me_calls == 1, "modules must not poll ME directly")
```
