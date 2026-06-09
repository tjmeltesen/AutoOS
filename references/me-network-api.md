# ME Network API (AE2 Integration)

Sources: [GTNH Wiki — Open Computers](https://wiki.gtnewhorizons.com/wiki/Open_Computers), [GTNH-OC-Lua-Documentation](https://github.com/Navatusein/GTNH-OC-Lua-Documentation)

Components sharing **CommonNetworkAPI**: `me_controller`, `me_interface`  
Extended by: `me_interface` (stocking, patterns), `me_exportbus` (export config)

## CommonNetworkAPI Methods

Available on `me_controller` and `me_interface`:

| Method | Returns | Description |
|--------|---------|-------------|
| `getItemsInNetwork([filter])` | MEItemStack[] | All items in ME network |
| `getFluidsInNetwork()` | MEFluidStack[] | All fluids in network |
| `getEssentiaInNetwork()` | EssentiaStack[] | Thaumcraft essentia (GTNH) |
| `allItems()` | iterator | Lazy iterator: `for item in me.allItems() do` |
| `getCraftables([filter])` | AECraftable[] | Craftable recipes |
| `getCpus()` | AECpuMetadata[] | CPU status (read-only crafting monitor) |
| `store(filter, dbAddr, [startSlot], [count])` | boolean | Store matching items to OC database |
| `getStoredPower()` | number | ME network stored power |
| `getMaxStoredPower()` | number | ME max stored power |
| `getAvgPowerInjection()` | number | Avg power injection |
| `getAvgPowerUsage()` | number | Avg power usage |
| `getIdlePowerUsage()` | number | Idle power draw |

## Data Types

### MEItemStack

```lua
{
  name = "minecraft:wool",       -- unlocalized ID
  label = "White Wool",          -- display name (use this)
  damage = 0,                    -- metadata
  size = 142800,                 -- count in network
  maxSize = 64,                  -- stack limit
  maxDamage = 0,
  hasTag = false,                -- has NBT
  isCraftable = true,            -- craftable in ME
  -- with Fluid Discretizer:
  fluidDrop = {
    amount = 142800,
    label = "Hydrochloric Acid",
    name = "hydrochloricacid"
  }
}
```

**Note:** When fluids are discretized, `label` becomes `"drop of <fluid>"` while `fluidDrop.label` is the actual fluid name.

### MEFluidStack

```lua
{
  name = "molten.solderingalloy",
  label = "Molten Soldering Alloy",
  amount = 50000,                -- mB
  hasTag = false,
  isCraftable = false
}
```

### Filter Tables

Pass to `getItemsInNetwork(filter)` or `getCraftables(filter)`:

```lua
me.getItemsInNetwork({ label = "drop of Hydrochloric Acid" })
me.getItemsInNetwork({ size = 2 })
me.getItemsInNetwork({ name = "gregtech:gt.metaitem.01" })
```

## Crafting API

### Request a Craft

```lua
local craftables = me.getCraftables({ label = "Soldering Alloy" })
if #craftables > 0 then
  local job = craftables[1].request(64, true)  -- amount, prioritizePower
  -- job is AECraftingJob userdata
end
```

| `request` Param | Default | Description |
|-----------------|---------|-------------|
| `amount` | 1 | Items to craft |
| `prioritizePower` | true | Prefer higher-tier CPU (co-processors, storage) |
| `cpuName` | nil | Target specific CPU by name |

### Craft Job Status (AECraftingJob)

| Method | Returns | Description |
|--------|---------|-------------|
| `isDone()` | boolean | Craft finished |
| `hasFailed()` | boolean | Craft failed |
| `isCanceled()` | boolean | Craft canceled |
| `isComputing()` | boolean | Still calculating pattern |

```lua
while not job.isDone() do
  if job.hasFailed() or job.isCanceled() then break end
  os.sleep(0.5)
end
```

## me_interface — Additional Methods

| Method | Description |
|--------|-------------|
| `getInterfaceConfiguration([slot])` | Item stocked in interface slot |
| `setInterfaceConfiguration(slot, dbAddr, dbIndex, [count])` | Stock item from database |
| `getFluidInterfaceConfiguration(side)` | Fluid config for side |
| `setFluidInterfaceConfiguration(side, dbAddr, dbIndex)` | Set fluid stocking |
| `getInterfacePattern(index)` | Get AE pattern |
| `setInterfacePatternInput(idx, dbAddr, dbIdx, count, inputIdx)` | Set pattern input |
| `setInterfacePatternOutput(idx, dbAddr, dbIdx, count, outputIdx)` | Set pattern output |
| `clearInterfacePatternInput(idx, inputIdx)` | Clear pattern input slot |
| `clearInterfacePatternOutput(idx, outputIdx)` | Clear pattern output slot |
| `storeInterfacePatternInput/Output(...)` | Copy pattern slot to database |

**Database required:** Item stacks cannot be passed directly as arguments. Load items into an OC `database` block first, then reference by `dbAddress` + slot index.

## me_exportbus Methods

| Method | Description |
|--------|-------------|
| `getExportConfiguration(side, [slot])` | Read export filter |
| `setExportConfiguration(side, slot, dbAddr, entry)` | Set export filter |
| `exportIntoSlot(side, slot)` | Trigger single export (pair with redstone upgrade) |

## AutoOS — Inventory Polling for State Cache

```lua
-- Poll once per tick into cache; modules read cache only
function poll_me_network(me, cache)
  cache.items = me.getItemsInNetwork()
  cache.fluids = me.getFluidsInNetwork()
  cache.timestamp = computer.uptime()
end

function get_item_count(cache, label)
  for _, stack in ipairs(cache.items) do
    if stack.label == label then return stack.size end
  end
  return 0
end

-- Consumption velocity (Phase 3)
function update_velocity(history, label, count, t)
  table.insert(history, { t = t, count = count })
  if #history > 60 then table.remove(history, 1) end
  if #history >= 2 then
    local old = history[1]
    local dt = t - old.t
    if dt > 0 then
      return (count - old.count) / dt  -- ΔR
    end
  end
  return 0
end

-- Time-to-depletion
function time_to_depletion(count, delta_r)
  if delta_r >= 0 then return math.huge end
  return count / math.abs(delta_r)
end
```

## CPU Metadata (getCpus)

Read-only view of active crafting jobs (like ME Terminal Crafting Status). Cannot issue crafts through CPU objects — use `getCraftables().request()` instead.
