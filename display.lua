--[[
  AutoOS — Read-Only Status Display

  A thin presentation layer for in-game verification. It renders a snapshot of
  the State Cache + arbitrator result onto a bound GPU/screen. It is strictly
  READ-ONLY with respect to the plant: it never calls setWorkAllowed(), never
  polls the gt_machine or ME network, and holds no control state. The kernel
  hands it a plain snapshot table that the modules/arbitrator already produced.

  This is NOT the Phase 4 charting UI — there are no history buffers, braille
  sparklines, or navigation. It is a fixed single-panel status readout meant to
  give visual feedback while validating Phase 2 in-game. Rendering is wrapped in
  a pcall by the kernel so a display fault can never stall the safety loop.

  References:
    references/gpu-and-display.md          (gpu bind/resolution/set/fill, color depth)
    references/performance-pitfalls.md      (only redraw what changed; cheap fills)
    README.md §4                            (full charts UI deferred to Phase 4)
]]

local Display = {}
Display.__index = Display

-- Palette (0xRRGGBB). Falls back silently if the GPU lacks setForeground.
local COLOR = {
  title = 0xFFFFFF,
  label = 0xAAAAAA,
  ok = 0x33FF33,
  idle = 0xFFCC33,
  fault = 0xFF3333,
  value = 0xFFFFFF,
}

-- gpu    : component.gpu proxy (real or mock) — required
-- screen : screen address to bind (optional; if omitted, uses the current bind)
-- opts   : { width, height } preferred panel size (clamped to maxResolution)
function Display.new(gpu, screen, opts)
  assert(gpu, "Display.new: a gpu proxy is required")
  opts = opts or {}

  local self = setmetatable({}, Display)
  self.gpu = gpu
  self.has_color = type(gpu.setForeground) == "function"

  if screen and type(gpu.bind) == "function" then
    gpu.bind(screen)
  end

  -- Pick a compact, predictable panel size when the GPU/screen allow it.
  local want_w, want_h = opts.width or 60, opts.height or 16
  if type(gpu.maxResolution) == "function" and type(gpu.setResolution) == "function" then
    local mw, mh = gpu.maxResolution()
    local w = math.min(want_w, mw or want_w)
    local h = math.min(want_h, mh or want_h)
    gpu.setResolution(w, h)
    self.width, self.height = w, h
  elseif type(gpu.getResolution) == "function" then
    self.width, self.height = gpu.getResolution()
  else
    self.width, self.height = want_w, want_h
  end

  self.width = self.width or want_w
  self.height = self.height or want_h
  self._max_row = 0 -- highest row written last frame, for clearing leftovers

  self:clear()
  return self
end

function Display:_color(c)
  if self.has_color and c then
    self.gpu.setForeground(c)
  end
end

function Display:clear()
  if type(self.gpu.fill) == "function" then
    self.gpu.fill(1, 1, self.width, self.height, " ")
  end
  self._max_row = 0
end

-- Write a string at (1, row), padded with spaces to the panel width so stale
-- characters from a previous, longer frame are overwritten.
function Display:_line(row, text, color)
  if row > self.height then return end
  text = text or ""
  if #text > self.width then
    text = text:sub(1, self.width)
  elseif #text < self.width then
    text = text .. string.rep(" ", self.width - #text)
  end
  self:_color(color)
  self.gpu.set(1, row, text)
  if row > self._max_row then self._max_row = row end
end

local function on_off(b) return b and "ON" or "OFF" end
local function yes_no(b) return b and "YES" or "NO" end

-- Render a snapshot table built by the kernel:
--   {
--     tick, work_allowed, active, has_work, eu_input,
--     fault = <maintenance reason|nil>,
--     pc = { label, stock, active, low, high } | nil,
--     action = <arbitrator action|nil>, committed = <bool>, requested_state = <bool|nil>,
--   }
function Display:render(s)
  s = s or {}
  local prev_max = self._max_row
  local row = 1

  self:_line(row, string.format("AutoOS Monitor            tick %s",
    tostring(s.tick or "?")), COLOR.title)
  row = row + 1
  self:_line(row, string.rep("-", self.width), COLOR.label)
  row = row + 2

  -- Machine state.
  self:_line(row, string.format("Machine    work=%s  active=%s  has_work=%s",
    on_off(s.work_allowed), yes_no(s.active), yes_no(s.has_work)),
    s.work_allowed and COLOR.ok or COLOR.idle)
  row = row + 1
  self:_line(row, string.format("Power      eu_in=%s",
    s.eu_input ~= nil and tostring(s.eu_input) or "n/a"), COLOR.value)
  row = row + 2

  -- Process control (Phase 2) — only when enabled.
  if s.pc then
    self:_line(row, "Process Control", COLOR.label)
    row = row + 1
    local pc = s.pc
    self:_line(row, string.format("  %s  stock=%s  band[%s..%s]",
      tostring(pc.label),
      pc.stock ~= nil and tostring(pc.stock) or "n/a",
      tostring(pc.low), tostring(pc.high)), COLOR.value)
    row = row + 1
    self:_line(row, string.format("  state: %s",
      pc.active and "ACTIVE (refilling)" or "IDLE (satisfied)"),
      pc.active and COLOR.ok or COLOR.idle)
    row = row + 2
  end

  -- Arbitrator outcome this tick.
  local act
  if s.committed then
    act = string.format("Arbitrator %s -> setWorkAllowed(%s)",
      tostring(s.action), on_off(s.requested_state))
  else
    act = "Arbitrator action: none (no hardware change)"
  end
  self:_line(row, act, COLOR.value)
  row = row + 2

  -- Maintenance / safety banner.
  if s.fault then
    self:_line(row, "MAINTENANCE FAULT - MACHINE SHUT DOWN", COLOR.fault)
    row = row + 1
    self:_line(row, "  " .. tostring(s.fault), COLOR.fault)
  else
    self:_line(row, "Maintenance OK", COLOR.ok)
  end
  row = row + 1

  -- Clear any rows left over from a taller previous frame.
  for r = row, prev_max do
    self:_line(r, "")
  end

  self:_color(COLOR.value)
end

return Display
