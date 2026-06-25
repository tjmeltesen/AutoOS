--[[
  AutoOS — OC serialization API mock
  Models: ser.serialize(value), ser.unserialize(string)

  OC serialization is a superset of Lua's — handles tables with cycles,
  preserves nil values in arrays, and includes type tags for OC objects.
  This mock implements a faithful subset that round-trips cleanly for
  all AutoOS data types.
]]

local OCSerializationMock = {}

--- OC serialize — same as a text serializer with OC-compatible output
function OCSerializationMock.serialize(value)
  return _serialize_impl(value, {})
end

--- OC unserialize — parse OC serialization format
function OCSerializationMock.unserialize(str)
  if type(str) ~= "string" then return nil end
  local fn, err = load("return " .. str)
  if not fn then return nil, err end
  local ok, result = pcall(fn)
  if not ok then return nil, tostring(result) end
  return result
end

-- Internal serialization
local function _serialize_impl(value, seen)
  local t = type(value)
  if t == "nil" then return "nil"
  elseif t == "boolean" then return value and "true" or "false"
  elseif t == "number" then return tostring(value)
  elseif t == "string" then return string.format("%q", value)
  elseif t == "table" then
    if seen[value] then return "nil /* cycle */" end
    seen[value] = true
    local parts = {}
    -- Detect array-style (consecutive integer keys starting at 1)
    local has_array = false
    local max_idx = 0
    for k in pairs(value) do
      if type(k) == "number" and k >= 1 then
        max_idx = math.max(max_idx, k)
        has_array = true
      else
        has_array = false
        break
      end
    end
    if has_array then
      for i = 1, max_idx do
        parts[#parts + 1] = _serialize_impl(value[i], seen)
      end
    else
      local keys = {}
      for k in pairs(value) do table.insert(keys, k) end
      table.sort(keys, function(a, b)
        if type(a) == type(b) then return tostring(a) < tostring(b) end
        return type(a) < type(b)
      end)
      for _, k in ipairs(keys) do
        parts[#parts + 1] = "[" .. _serialize_impl(k, seen) .. "]=" .. _serialize_impl(value[k], seen)
      end
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil /* unsupported: " .. t .. " */"
end

return OCSerializationMock
