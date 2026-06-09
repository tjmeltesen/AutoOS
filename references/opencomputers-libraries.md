# OpenComputers — Core Lua Libraries

Sources: [Computer API](https://ocdoc.cil.li/api:computer), [Event API](https://ocdoc.cil.li/api:event), [Term API](https://ocdoc.cil.li/api:term), [Sides API](https://ocdoc.cil.li/api:sides), [Signals](https://ocdoc.cil.li/component:signals)

## computer

```lua
local computer = require("computer")
```

| Function | Returns | Description |
|----------|---------|-------------|
| `address()` | string | This computer's component address |
| `tmpAddress()` | string | Temporary filesystem address |
| `freeMemory()` | number | Free RAM in bytes |
| `totalMemory()` | number | Total RAM in bytes |
| `energy()` | number | Energy in network (EU for GTNH) |
| `maxEnergy()` | number | Max energy capacity |
| `uptime()` | number | Seconds since boot (real time, pauses with game) |
| `shutdown([reboot])` | — | Shut down; `true` = reboot |
| `getBootAddress()` | string | Boot filesystem address |
| `setBootAddress(addr)` | — | Set boot filesystem |
| `runlevel()` | string\|number | Current runlevel (`S`, `1`, etc.) |
| `users()` | string, ... | Registered user list |
| `addUser(name)` | boolean | Register user |
| `removeUser(name)` | boolean | Unregister user |
| `pushSignal(name, ...)` | — | Queue a custom signal |
| `pullSignal([timeout])` | name, ... | Pull next signal (blocks) |
| `beep([freq, duration])` | — | Beep; freq 20–2000 Hz, or dot/dash pattern |
| `getDeviceInfo()` | table | Installed device info |

**AutoOS usage:** `beep()` for maintenance alarms; `uptime()` for tick timing; `pullSignal`/`event.pull` for main loop.

## event

```lua
local event = require("event")
```

| Function | Description |
|----------|-------------|
| `listen(name, callback)` | Register background handler; returns event id |
| `ignore(name, callback)` | Unregister handler |
| `timer(interval, callback[, times])` | Periodic timer; `math.huge` = infinite |
| `cancel(timerId)` | Stop a timer |
| `pull([timeout], [name], ...)` | Block until matching event |
| `pullFiltered([timeout], filter)` | Pull with custom filter function |
| `pullMultiple(...)` | Pull any of several event names |
| `push(name, ...)` | Alias for `computer.pushSignal` |
| `onError(message)` | Global handler for listener errors |

### Main Loop Pattern (AutoOS)

```lua
local TICK_INTERVAL = 0.5  -- 500ms target

while true do
  local deadline = computer.uptime() + TICK_INTERVAL
  run_modules()       -- logic only, no hardware
  commit_arbitrator() -- sole hardware write path

  local remaining = deadline - computer.uptime()
  if remaining > 0 then
    event.pull(remaining)
  end
end
```

### Interrupts (OpenOS 1.6.4+)

| Input | Effect |
|-------|--------|
| Ctrl+C | Soft interrupt → `"interrupted"` event |
| Ctrl+Alt+C | Hard interrupt → throws error |

## term

```lua
local term = require("term")
```

Simplified screen I/O. Requires primary GPU + screen.

| Function | Description |
|----------|-------------|
| `isAvailable()` | GPU + screen present |
| `write(value[, wrap])` | Write text at cursor |
| `read([options])` | Read user input |
| `clear()` | Clear screen, cursor to (1,1) |
| `clearLine()` | Clear current line |
| `getCursor()` / `setCursor(col, row)` | Cursor position |
| `getViewport()` | Width, height, offsets |
| `gpu()` | Underlying GPU proxy |
| `bind(gpu)` | Rebind terminal to different GPU |
| `screen()` | Bound screen address |
| `pull(...)` | Like `event.pull` with cursor blink |

## sides

```lua
local sides = require("sides")
```

Direction constants for redstone, transposer, etc.

| Name | Number | Aliases |
|------|--------|---------|
| bottom | 0 | down, negy |
| top | 1 | up, posy |
| back | 2 | north, negz |
| front | 3 | south, posz, forward |
| right | 4 | west, negx |
| left | 5 | east, posx |

Bidirectional: `sides[1]` → `"top"`, `sides.top` → `1`.

## Key Signals

### Computer / Component

| Signal | Parameters |
|--------|------------|
| `component_available` | `componentType` |
| `component_unavailable` | `componentType` |
| `term_available` | — |
| `term_unavailable` | — |

### Screen (Tier 2+)

| Signal | Parameters |
|--------|------------|
| `touch` | `screenAddr, x, y, button, playerName` |
| `drag` | `screenAddr, x, y, button, playerName` |
| `drop` | `screenAddr, x, y, button, playerName` |
| `scroll` | `screenAddr, x, y, direction, playerName` |
| `screen_resized` | `screenAddr, newW, newH` |

### Keyboard

| Signal | Parameters |
|--------|------------|
| `key_down` | `keyboardAddr, char, code, playerName` |
| `key_up` | `keyboardAddr, char, code, playerName` |
| `clipboard` | `keyboardAddr, value, playerName` |

### Redstone

| Signal | Parameters |
|--------|------------|
| `redstone_changed` | `addr, side, oldValue, newValue[, color]` |

### Modem

| Signal | Parameters |
|--------|------------|
| `modem_message` | `receiverAddr, senderAddr, port, distance, ...` |

### Modem Example

```lua
local modem = component.modem
modem.open(123)
modem.broadcast(123, "status_request")

local _, _, from, port, dist, payload = event.pull("modem_message")
```

## Lua Version

OpenComputers in GTNH uses **Lua 5.2** (upstream docs may mention 5.3). Desktop testing should use Lua 5.2 or 5.3 per README.
