--[[
  AutoOS — Registry persistence (serialize recipe rows to a Lua file)

  Tiny, dependency-free serializer for the subset the registry stores:
  strings, numbers, booleans nested one level deep. Kept separate from
  ae_recipe_registry.lua so neither file grows large.
]]

local RegistryStore = {}

local function quote(s)
  return string.format("%q", tostring(s))
end

local function value(v)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  return quote(v)
end

--- Serialize a { recipe_key = {fields...} } table to a `return {...}` string.
---@param rows table
---@return string
function RegistryStore.serialize(rows)
  local out = { "return {\n" }
  for key, row in pairs(rows) do
    out[#out + 1] = string.format("  [%s] = {\n", quote(key))
    for field, v in pairs(row) do
      if type(v) ~= "table" and type(v) ~= "function" then
        out[#out + 1] = string.format("    [%s] = %s,\n", quote(field), value(v))
      end
    end
    out[#out + 1] = "  },\n"
  end
  out[#out + 1] = "}\n"
  return table.concat(out)
end

--- Write serialized rows to disk. Returns ok, err.
function RegistryStore.save(path, rows)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(RegistryStore.serialize(rows))
  f:close()
  return true
end

--- Load rows from disk. Returns table (possibly empty) — never errors hard.
function RegistryStore.load(path)
  local chunk = loadfile(path)
  if not chunk then return nil end
  local ok, rows = pcall(chunk)
  if ok and type(rows) == "table" then return rows end
  return nil
end

return RegistryStore
