#!/usr/bin/env lua
--[[
  AutoOS — Descriptor cache tests

  Run: lua55 tests/descriptor_cache_test.lua
]]

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "tests/descriptor_cache_test.lua"
local here = script:match("^(.*)[/\\]") or "."
package.path = table.concat({
  here .. sep .. "?.lua",
  here .. sep .. ".." .. sep .. "subnet_broker" .. sep .. "?.lua",
  package.path,
}, ";")

local DescriptorCache = require("descriptor_cache")

local ESC = string.char(27)
local function color(c, t) return ESC .. "[" .. c .. "m" .. t .. ESC .. "[0m" end
local function green(t) return color("32", t) end
local function red(t) return color("31", t) end
local function bold(t) return color("1", t) end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1; io.write(green("  PASS  ") .. name)
  else failed = failed + 1; io.write(red("  FAIL  ") .. name) end
  if detail then io.write("  -  " .. tostring(detail)) end
  io.write("\n")
end

local function new_fixture()
  local db = {}
  local network_items = {
    { name = "gregtech:gt.integrated_circuit", damage = 18, label = "Integrated Circuit", size = 8 },
    { name = "minecraft:redstone", damage = 0, label = "Redstone", size = 64 },
    { name = "ae2fc:fluid_drop", damage = 0, label = "drop of Oxygen", size = 1000 },
  }

  local function take_item(filter, count)
    for _, it in ipairs(network_items) do
      if it.name == filter.name
        and (filter.damage == nil or it.damage == filter.damage)
        and (not filter.label or it.label == filter.label)
        and (it.size or 0) >= count then
        it.size = it.size - count
        return { name = it.name, damage = it.damage, label = it.label }
      end
    end
    return nil
  end

  local component = {
    list = function()
      return { ["db-1"] = "database" }
    end,
    proxy = function(address, hint)
      if address ~= "db-1" then return nil end
      if hint and hint ~= "database" then return nil end
      return {
        get = function(slot) return db[slot] end,
        set = function(slot, name, damage) db[slot] = { name = name, damage = damage or 0 }; return true end,
        clear = function(slot) db[slot] = nil; return true end,
      }
    end,
  }

  local iface = {
    store = function(filter, db_addr, slot, count)
      if db_addr ~= "db-1" then return false end
      local picked = take_item(filter, count or 1)
      if not picked then return false end
      db[slot] = picked
      return true
    end,
    getItemsInNetwork = function(filter)
      local out = {}
      for _, it in ipairs(network_items) do
        if (not filter.name or filter.name == it.name) and (it.size or 0) > 0 then
          out[#out + 1] = { name = it.name, damage = it.damage, label = it.label, size = it.size }
        end
      end
      return out
    end,
  }

  local cfg = {
    database_address = "db-1",
    database_slot_count = 2,
    circuit_item_name = "gregtech:gt.integrated_circuit",
  }
  local cache = DescriptorCache.new({ config = cfg, component = component })
  return { cache = cache, iface = iface, db = db }
end

io.write("\n" .. bold("AutoOS Descriptor Cache Tests") .. "\n")
io.write(string.rep("-", 60) .. "\n")

do
  local fx = new_fixture()
  local ok1, slot1 = fx.cache:ensure_item(fx.iface, { name = "minecraft:redstone", damage = 0, count = 1 })
  local ok2, slot2 = fx.cache:ensure_item(fx.iface, { name = "minecraft:redstone", damage = 0, count = 1 })
  check("ensure_item cache hit reuses slot", ok1 and ok2 and slot1 == slot2)
end

do
  local fx = new_fixture()
  local ok1, slot1 = fx.cache:ensure_circuit(fx.iface, 18)
  local ok2, slot2 = fx.cache:ensure_fluid(fx.iface, { fluid_label = "Oxygen" })
  local ok3, slot3 = fx.cache:ensure_item(fx.iface, { name = "minecraft:redstone", damage = 0, count = 1 })
  check("LRU eviction works in tiny DB", ok1 and ok2 and ok3 and slot3 >= 1 and slot3 <= 2)
  check("slot holds last descriptor", fx.db[slot3] and fx.db[slot3].name == "minecraft:redstone")
end

do
  local fx = new_fixture()
  local ok, slot = fx.cache:ensure_item(fx.iface, { name = "minecraft:redstone", damage = 0, count = 1 })
  local released = fx.cache:release_slots({ slot })
  check("release_slots clears db slot", ok and released == 1 and fx.db[slot] == nil)
  local dump = fx.cache:debug_dump()
  local entries = 0
  for _ in pairs(dump) do entries = entries + 1 end
  check("release_slots clears cache maps", entries == 0)
end

do
  local fx = new_fixture()
  local ok1, slot1 = fx.cache:ensure_item(fx.iface, { name = "minecraft:redstone", damage = 0, count = 1 })
  local ok2, slot2 = fx.cache:ensure_item(fx.iface, { name = "minecraft:redstone", damage = 0, count = 1 })
  local released1 = fx.cache:release_slots({ slot1 })
  local still_present = fx.db[slot1] ~= nil
  local released2 = fx.cache:release_slots({ slot2 })
  check("descriptor refcount keeps shared slot until final release",
    ok1 and ok2 and slot1 == slot2 and released1 == 1 and still_present and released2 == 1 and fx.db[slot1] == nil)
end

io.write(string.rep("-", 60) .. "\n")
io.write(string.format("%s   %s passed, %s failed\n",
  bold("Descriptor cache result:"), green(tostring(passed)),
  failed == 0 and tostring(failed) or red(tostring(failed))))
os.exit(failed == 0 and 0 or 1)
