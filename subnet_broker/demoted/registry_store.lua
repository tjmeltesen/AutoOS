--[[
  AutoOS — Registry persistence (broker deploy copy)
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

function RegistryStore.save(path, rows)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(RegistryStore.serialize(rows))
  f:close()
  return true
end

function RegistryStore.load(path)
  local chunk = loadfile(path)
  if not chunk then return nil end
  local ok, rows = pcall(chunk)
  if ok and type(rows) == "table" then return rows end
  return nil
end

return RegistryStore
