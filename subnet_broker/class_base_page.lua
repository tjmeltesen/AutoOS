-- class_base_page.lua - Abstract base class for all broker UI pages
-- Lua 5.2 metatable-based OOP. Child pages inherit via setmetatable({}, {__index = BasePage}).
-- ponytail: no virtual method enforcement — child pages document what they override.

local BasePage = {}; BasePage.__index = BasePage

--- Constructor. Accepts the deps table (gpu, screen_dimensions, broker_state, etc.).
--- Child classes call BasePage.new(deps) then setmetatable(o, ChildClass).
function BasePage.new(deps)
  deps = deps or {}
  local o = setmetatable({}, BasePage)
  o.deps = deps
  o._w = 80    -- screen width, updated by router before render
  o._h = 25    -- screen height, updated by router before render
  o.data = {}  -- page-local mutable state, populated by set_data()
  o._hitboxes = {}  -- touch hitbox registry, cleared on unmount
  return o
end

--- Called each render cycle (~2fps). Child classes MUST override.
--- The router updates self._w and self._h before calling this.
function BasePage:render() end

--- Called on key events. event = { code=scancode, char=ASCII } or { type="touch", x, y }.
--- Automatically intercepts touch events and checks against registered hitboxes.
--- Return true if handled, false/nil to let router handle it.
function BasePage:handle_input(event)
  -- Touch hitbox interception
  local event_type = event.type or (type(event[1]) == "string" and event[1])
  if event_type == "touch" then
    local tx, ty = event.x or event[3], event.y or event[4]
    if tx and ty then
      for _, box in ipairs(self._hitboxes or {}) do
        if tx >= box.x and tx < (box.x + box.w) and
           ty >= box.y and ty < (box.y + box.h) then
          if box.callback then box.callback(self.deps, event) end
          return true
        end
      end
    end
    return false
  end
  return false
end

--- Called when this page becomes active (after navigation).
--- Use for one-time setup: reset scroll, reload state.
function BasePage:on_mount() end

--- Called when navigating away from this page.
--- Use for cleanup: save state, cancel editing, clear hitboxes.
function BasePage:on_unmount()
  self._hitboxes = {}
end

--- Register a touch hitbox for this page.
--- @param id string unique identifier for this hitbox
--- @param x, y, w, h number bounding box (1-indexed, inclusive)
--- @param callback_fn function(deps, event_data) called on touch within bounds
function BasePage:register_hitbox(id, x, y, w, h, callback_fn)
  table.insert(self._hitboxes, {
    id = id,
    x = x, y = y, w = w, h = h,
    callback = callback_fn,
  })
end

--- Called by router before render when fresh broker data is available.
--- Merges data_table into self.data. Override for special merge logic.
function BasePage:set_data(t)
  if type(t) == "table" then
    for k, v in pairs(t) do
      self.data[k] = v
    end
  end
end

--- Returns true when the page should block global navigation keys
--- (1/2/3, Tab, Backspace). Config page overrides when editing.
function BasePage:is_modal()
  return false
end

return BasePage
