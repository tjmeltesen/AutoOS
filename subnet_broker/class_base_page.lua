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
  return o
end

--- Called each render cycle (~2fps). Child classes MUST override.
--- The router updates self._w and self._h before calling this.
function BasePage:render() end

--- Called on key events. event = { code=scancode, char=ASCII }.
--- Return true if handled, false/nil to let router handle it.
function BasePage:handle_input(event)
  return false
end

--- Called when this page becomes active (after navigation).
--- Use for one-time setup: reset scroll, reload state.
function BasePage:on_mount() end

--- Called when navigating away from this page.
--- Use for cleanup: save state, cancel editing.
function BasePage:on_unmount() end

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
