--[[
  AutoOS — OC filesystem API mock
  Models: fs.open(), fs.exists(), fs.isDirectory(), fs.makeDirectory(), fs.remove()

  Usage:
    local mock_fs = OCFilesystemMock.new({ files = { ["/home/test.lua"] = "print('hi')" } })
    local f = mock_fs.open("/home/test.lua", "r")
    local content = mock_fs.read(f, 1024)
]]

local OCFilesystemMock = {}

function OCFilesystemMock.new(opts)
  opts = opts or {}
  local files = {}
  if opts.files then
    for path, content in pairs(opts.files) do
      files[path] = content
    end
  end
  local self = {
    _files = files,
    _dirs = {},
    _call_counts = { open = 0, exists = 0, isDirectory = 0, makeDirectory = 0, remove = 0 },
  }
  setmetatable(self, { __index = OCFilesystemMock })
  return self
end

--- fs.open(path, mode) -> file handle | nil, error
function OCFilesystemMock.open(self, path, mode)
  self._call_counts.open = self._call_counts.open + 1
  mode = mode or "r"
  if mode == "r" or mode == "rb" then
    if self._files[path] ~= nil then
      return { _path = path, _content = self._files[path], _pos = 1, _closed = false }
    end
    return nil, "file not found: " .. path
  end
  if mode == "w" or mode == "wb" or mode == "a" then
    local handle = { _path = path, _content = mode == "a" and (self._files[path] or "") or "", _pos = 1, _closed = false }
    self._files[path] = handle._content
    return handle
  end
  return nil, "unsupported mode: " .. tostring(mode)
end

--- Read from a file handle
function OCFilesystemMock.read(self, handle, count)
  if not handle or handle._closed then return nil end
  local content = self._files[handle._path]
  if not content then return nil end
  local rest = content:sub(handle._pos)
  if #rest == 0 then return nil end
  if count then
    local chunk = rest:sub(1, count)
    handle._pos = handle._pos + #chunk
    return chunk
  end
  handle._pos = #content + 1
  return rest
end

--- Write to a file handle
function OCFilesystemMock.write(self, handle, data)
  if not handle or handle._closed then return nil, "handle closed" end
  self._files[handle._path] = self._files[handle._path] or ""
  self._files[handle._path] = self._files[handle._path] .. data
  return true
end

--- Close a file handle
function OCFilesystemMock.close(self, handle)
  if handle then handle._closed = true end
end

--- fs.exists(path) -> boolean
function OCFilesystemMock.exists(self, path)
  self._call_counts.exists = self._call_counts.exists + 1
  return self._files[path] ~= nil
end

--- fs.isDirectory(path) -> boolean
function OCFilesystemMock.isDirectory(self, path)
  self._call_counts.isDirectory = self._call_counts.isDirectory + 1
  return self._dirs[path] == true
end

--- fs.makeDirectory(path) -> boolean
function OCFilesystemMock.makeDirectory(self, path)
  self._call_counts.makeDirectory = self._call_counts.makeDirectory + 1
  self._dirs[path] = true
  return true
end

--- fs.remove(path) -> boolean
function OCFilesystemMock.remove(self, path)
  self._call_counts.remove = self._call_counts.remove + 1
  if self._files[path] ~= nil then
    self._files[path] = nil
    return true
  end
  if self._dirs[path] then
    self._dirs[path] = nil
    return true
  end
  return false
end

function OCFilesystemMock.get_call_counts(self)
  return self._call_counts
end

return OCFilesystemMock
