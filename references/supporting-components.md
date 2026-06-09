# Supporting OpenComputers Components

Sources: [GTNH-OC-Lua-Documentation](https://github.com/Navatusein/GTNH-OC-Lua-Documentation), [ocdoc.cil.li](https://ocdoc.cil.li/)

## redstone

Component from **Redstone Card** (in computer) or **Redstone I/O Block**.

```lua
local sides = require("sides")
local rs = component.redstone

rs.setOutput(sides.back, 15)       -- emit max signal
local val = rs.getInput(sides.left) -- read input
```

| Method | Description |
|--------|-------------|
| `getInput([side])` | Read redstone input (0-15+, all sides if no arg) |
| `getOutput([side])` | Read current output |
| `setOutput(side, value)` | Set output strength |
| `setOutput(table)` | Set multiple sides at once |
| `getBundledInput/Output(...)` | Project Red bundled cable |
| `setBundledOutput(...)` | Set bundled output |
| `get/setWirelessInput/Output()` | Wireless redstone |
| `get/setWirelessFrequency()` | Wireless frequency |
| `get/setWakeThreshold()` | Wake computer on signal change |

**Signal:** `redstone_changed(addr, side, oldValue, newValue[, color])`

**AutoOS use:** External machine enable lines, export bus triggers (redstone upgrade on "only on signal").

## modem

Component from **Network Card** (wired) or **Wireless Network Card**.

```lua
local modem = component.modem
modem.open(100)
modem.broadcast(100, "ping", os.time())
modem.send(target_addr, 100, "command", "shutdown")
```

| Method | Description |
|--------|-------------|
| `open(port)` | Listen on port (1-65535) |
| `close([port])` | Close port or all ports |
| `isOpen(port)` | Check if port open |
| `send(addr, port, ...)` | Send to specific address |
| `broadcast(port, ...)` | Broadcast on port |
| `isWireless()` / `isWired()` | Card type |
| `maxPacketSize()` | Max message size |
| `getStrength()` / `setStrength(n)` | Wireless range (costs more energy) |
| `getWakeMessage()` / `setWakeMessage(msg, fuzzy)` | Wake on matching packet |

**Signal:** `modem_message(receiverAddr, senderAddr, port, distance, ...)`

Payload types limited to: nil, boolean, number, string (no tables).

## database

OC **Database** block — stores item descriptors for ME interface/export configuration.

| Method | Description |
|--------|-------------|
| `get(slot)` | ItemStack descriptor at slot |
| `set(slot, id, damage, [nbt])` | Write item (NBT as JSON string) |
| `clear(slot)` | Clear slot |
| `indexOf(hash)` | Find slot by hash (-1 if missing) |
| `computeHash(slot)` | Hash of slot contents |
| `copy(fromSlot, toSlot, [dbAddr])` | Copy entry |
| `clone(dbAddr)` | Copy entire database |

**Required for:** `me_interface.setInterfaceConfiguration()`, pattern I/O methods.

## transposer

OC **Transposer** — moves items/fluids between adjacent inventories.

Key methods (partial):

| Method | Description |
|--------|-------------|
| `transferItem(fromSide, fromSlot, toSide, toSlot[, count])` | Move items |
| `transferFluid(fromSide, toSide[, count])` | Move fluids |
| `getSlotStackSize(side, slot)` | Stack size |
| `getTankLevel(side)` | Fluid level |
| `compareStackToDatabase(side, slot, dbAddr, dbSlot)` | Compare item to DB entry |
| `store(side, slot, dbAddr, dbSlot)` | Store item in database |
| `getInventorySize(side)` | Slots on side |

Sides use `sides` constants relative to transposer orientation.

## level_maintainer

AE2 **Level Maintainer** via Adapter. Alternative to writing custom stock logic.

| Method | Description |
|--------|-------------|
| `getSlot(slot)` | LevelMaintainerSlot descriptor or nil |
| `active()` | Connected to AE network |
| `isDone(slot)` | Slot finished crafting |
| `isEnable(slot)` | Slot enabled state |

**Note:** `setSlot()` documented as broken in GTNH 2.6.1 per community docs.

## inventory_controller

Upgrade in robot/computer for scanning player/inventory.

| Method | Description |
|--------|-------------|
| `equip()` | Equip held item |
| `suckIntoSlot([side, [slot]])` | Pull item into slot |

## tps_card (GTNH-Specific)

Monitors server TPS from within OpenComputers. Useful for detecting lag before "Computer Too Busy" errors. See [tps-card.lua](https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/tps-card.lua) for full method list.

## sound

**Sound Card** — play arbitrary sounds for alarms.

Useful for maintenance alerts alongside `computer.beep()`.

## chat_box

**Chat Box** — send messages to Minecraft chat. Useful for remote alerting.

## Practical AutoOS Wiring

```
[OC Server]
  ├── Graphics Card T3 → Screen (monitoring)
  ├── Redstone Card → Machine enable line (optional)
  ├── Network Card → Remote monitoring
  └── Adapter → GT Controller (gt_machine)
  └── Adapter → ME Interface (me_interface)
```
