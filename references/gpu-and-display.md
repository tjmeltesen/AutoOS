# GPU, Screen & Display APIs (Phase 4)

Sources: [GPU Component](https://ocdoc.cil.li/component:gpu), [Screen Component](https://ocdoc.cil.li/component:screen), [Term API](https://ocdoc.cil.li/api:term), [GTNH-OC-Lua-Documentation — gpu.lua](https://github.com/Navatusein/GTNH-OC-Lua-Documentation/blob/main/lua/components/gpu.lua)

## Setup

```lua
local component = require("component")
local gpu = component.gpu
local screen = component.screen

gpu.bind(screen.address)
local w, h = gpu.getResolution()
```

## screen Component

| Method | Returns | Description |
|--------|---------|-------------|
| `isOn()` | boolean | Screen powered |
| `turnOn()` | boolean, boolean | Power on |
| `turnOff()` | boolean, boolean | Power off |
| `getAspectRatio()` | w, h | Multiblock screen block count |
| `getKeyboards()` | table | Attached keyboards |
| `setPrecise(enabled)` | boolean | Sub-pixel touch (Tier 3) |
| `isPrecise()` | boolean | Precise mode state |
| `setTouchModeInverted(enabled)` | boolean | Sneak-activate opens GUI |
| `isTouchModeInverted()` | boolean | Inverted touch state |

## gpu — Binding & Resolution

| Method | Description |
|--------|-------------|
| `bind(address[, reset=true])` | Bind to screen; resets screen if reset=true |
| `getScreen()` | Bound screen address |
| `maxResolution()` | Max w, h (min of GPU tier and screen) |
| `getResolution()` / `setResolution(w, h)` | Current / set resolution |
| `getSize()` | Viewport size |
| `getViewport()` / `setViewport(w, h)` | Visible sub-region |
| `maxDepth()` / `getDepth()` / `setDepth(1\|4\|8)` | Color depth in bits |

## gpu — Drawing

| Method | Description |
|--------|-------------|
| `get(x, y)` | char, fg, bg, [fgPal], [bgPal] at position |
| `set(x, y, value[, vertical])` | Write string at position |
| `fill(x, y, w, h, char)` | Fill rectangle (space = cheaper) |
| `copy(x, y, w, h, tx, ty)` | Copy screen region |
| `setForeground(color[, isPalette])` | Text color (0xRRGGBB or palette 0-15) |
| `setBackground(color[, isPalette])` | Background color |
| `getPaletteColor(idx)` / `setPaletteColor(idx, value)` | Palette management |

## gpu — Video RAM Buffers (Off-Screen)

For chart rendering without flicker:

| Method | Description |
|--------|-------------|
| `allocateBuffer([w, h])` | Create off-screen buffer; returns index |
| `setActiveBuffer(index)` | Switch draw target (0 = screen) |
| `getActiveBuffer()` | Current buffer index |
| `buffers()` | List of allocated buffer indexes |
| `freeBuffer([index])` | Free buffer |
| `freeAllBuffers()` | Release all VRAM |
| `getBufferSize([index])` | Buffer dimensions |
| `totalMemory()` / `freeMemory()` | VRAM usage |
| `bitblt(dst, dstX, dstY, w, h, src, srcX, srcY)` | Fast buffer→buffer/screen copy |

**Chart pattern:**
1. `setActiveBuffer(chart_buf)`
2. Draw chart into buffer
3. `setActiveBuffer(0)`
4. `bitblt(0, 1, 1, chart_w, chart_h, chart_buf, 1, 1)` — blit to screen

Buffers are released on reboot.

## term — Simplified I/O

Use for text status panels; use raw `gpu` for performance-critical graphics.

```lua
local term = require("term")
if term.isAvailable() then
  term.clear()
  term.setCursor(1, 1)
  term.write("AutoOS Status\n")
  term.write(string.format("Soldering Alloy: %d L\n", volume))
end
```

## Pseudo-Braille Charts

Map history vectors to block characters for sparkline-style charts:

```lua
-- Braille upper 8 dots: U+2800 block, offset by bit pattern
local BRAILLE_BASE = 0x2800
local function spark_char(value, min, max)
  local range = max - min
  local norm = range > 0 and (value - min) / range or 0
  local level = math.floor(norm * 7)  -- 0-7 vertical steps
  return utf8.char(BRAILLE_BASE + level * 32 + 1)
end
```

(Exact braille encoding depends on desired resolution; `gpu.set()` accepts UTF-8 strings at Tier 2+ screens.)

## Throttled Refresh (AutoOS Phase 4)

```lua
local event = require("event")
local REFRESH_INTERVAL = 1.0  -- 1 second frame tick

local timer_id = event.timer(REFRESH_INTERVAL, function()
  render_dashboard(cache.history)
end, math.huge)
```

Only redraw changed regions to minimize GPU energy cost.

## Color Depth Reference

| Depth | Name | Colors |
|-------|------|--------|
| 1 | OneBit | 2 (mono) |
| 4 | FourBit | 16 (palette) |
| 8 | EightBit | 256 |

Tier 1 GPU max: 1-bit. Tier 2: 4-bit. Tier 3: 8-bit.

## Signals for Interactive UI

| Signal | Use |
|--------|-----|
| `touch` | Button clicks on Tier 2+ screens |
| `key_down` / `key_up` | Keyboard input |
| `screen_resized` | Resolution changed |
