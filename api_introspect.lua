--[[
  AutoOS — In-Game API Introspection Script
  Paste into /home/api_introspect.lua on the broker computer, then run:
    api_introspect
  Output: /home/api_reference.txt
]]

local component = require("component")
local computer = require("computer")
local event = require("event")
local out = io.open("/home/api_reference.txt", "w")

local function w(fmt, ...)
  out:write(string.format(fmt, ...))
  out:write("\n")
end

w("=== AutoOS In-Game API Reference ===")
w("Generated: %s", os.date("%Y-%m-%d %H:%M:%S"))
w("Computer Uptime: %.1fs", computer.uptime())
w("")

-- ── Standard OC APIs ──────────────────────────────────────────────
w("=== STANDARD OC APIs ===")
w("")

local function document_module(name, methods)
  w("--- %s ---", name)
  local ok, mod = pcall(require, name)
  if not ok or not mod then
    w("  ERROR: require(%q) failed: %s", name, tostring(mod))
    return
  end
  for _, m in ipairs(methods) do
    local t = type(mod[m])
    w("  %s.%s: %s", name, m, t)
  end
  w("")
end

document_module("component", { "list", "proxy", "isAvailable", "type", "slot", "fields", "doc", "invoke" })
document_module("computer", { "uptime", "address", "tmpAddress", "freeMemory", "totalMemory", "energy", "maxEnergy", "beep", "getProgramLocations", "isRobot", "maxSignal", "pushSignal", "pullSignal", "realTime" })
document_module("event", { "pull", "pullFiltered", "listen", "ignore", "cancel", "timer", "on", "off" })
document_module("thread", { "create", "list" })
document_module("os", { "sleep", "date", "time", "difftime", "clock", "exit", "setenv", "getenv" })
document_module("term", { "read", "write", "clear", "getCursor", "setCursor", "getViewport", "setViewport", "gpu", "isAvailable" })
document_module("serialization", { "serialize", "unserialize" })
document_module("sides", { "down", "up", "north", "south", "west", "east" })
document_module("keyboard", { "isControlDown", "isKeyDown", "isShiftDown", "isAltDown" })

-- ── Network Components ──────────────────────────────────────────────
w("=== CONNECTED COMPONENTS ===")
w("")

local list = component.list()
local type_counts = {}

for addr, ctype in pairs(list) do
  type_counts[ctype] = (type_counts[ctype] or 0) + 1
end

w("Component type summary:")
for ctype, n in pairs(type_counts) do
  w("  %s: %d", ctype, n)
end
w("")

-- ── Component Methods ──────────────────────────────────────────────
w("=== COMPONENT METHODS BY TYPE ===")
w("")
w("(Methods discovered via component.proxy + type inspection)")
w("(Methods marked [nil] exist but returned nil on info-style call — likely state-dependent)")
w("(Methods marked [f] are fields, not functions)")
w("")

-- Key types we care about
local key_types = {
  "me_interface", "transposer", "database", "gt_machine",
  "redstone", "modem", "inventory_controller", "adapter",
  "fluid_hatch", "item_hatch", "tank_controller",
}

-- Generic sniffer for any proxy
local function sniff_proxy(proxy, label)
  w("--- %s ---", label)
  if not proxy then
    w("  (nil proxy)")
    w("")
    return
  end

  local funcs, fields = {}, {}

  for k, v in pairs(proxy) do
    if type(v) == "function" then
      funcs[#funcs + 1] = k
    elseif type(k) == "string" then
      fields[#fields + 1] = { key = k, val = tostring(v):sub(1, 80) }
    end
  end

  table.sort(funcs)
  table.sort(fields, function(a, b) return a.key < b.key end)

  if #funcs > 0 then
    w("  Methods (%d):", #funcs)
    for _, fn in ipairs(funcs) do
      w("    %s()", fn)
    end
  end

  if #fields > 0 then
    w("  Fields (%d):", #fields)
    for _, f in ipairs(fields) do
      w("    %s = %s", f.key, f.val)
    end
  end

  if #funcs == 0 and #fields == 0 then
    w("  (empty proxy — no methods or fields)")
  end
  w("")
end

-- Sniff one of each type
local done_types = {}
for addr, ctype in pairs(list) do
  if not done_types[ctype] then
    done_types[ctype] = true
    local ok, proxy = pcall(component.proxy, addr)
    if ok and proxy then
      sniff_proxy(proxy, ctype .. " (" .. addr:sub(1, 8) .. "…)")
    else
      w("--- %s ---", ctype)
      w("  ERROR proxying %s: %s", addr:sub(1, 8) .. "…", tostring(proxy))
      w("")
    end
  end
end

-- ── Detailed Key Type Methods (first instance) ─────────────────────
w("")
w("=== DETAILED KEY COMPONENTS ===")
w("")

for _, ctype in ipairs(key_types) do
  for addr, t in pairs(list) do
    if t == ctype then
      local ok, proxy = pcall(component.proxy, addr)
      if ok and proxy then
        w("--- %s @ %s ---", ctype, addr)
        w("Full address: %s", addr)

        local methods = {}
        for k, v in pairs(proxy) do
          if type(v) == "function" then
            methods[#methods + 1] = k
          end
        end
        table.sort(methods)

        w("Method list (%d):", #methods)
        for _, m in ipairs(methods) do
          w("  %s", m)
        end

        -- Try to describe well-known methods with safe test calls
        if ctype == "me_interface" then
          w("")
          w("  --- me_interface detail ---")
          -- getItemsInNetwork
          if proxy.getItemsInNetwork then
            local ok_items, items = pcall(proxy.getItemsInNetwork, { name = "gregtech:gt.integrated_circuit" })
            if ok_items and type(items) == "table" then
              w("  getItemsInNetwork({name=\"gregtech:gt.integrated_circuit\"}): %d results", #items)
              if #items > 0 then
                local ex = items[1]
                w("    Example: name=%s damage=%s label=%s size=%s",
                  tostring(ex.name), tostring(ex.damage), tostring(ex.label), tostring(ex.size))
              end
            else
              w("  getItemsInNetwork(): ERROR — %s", tostring(items))
            end
          end
          -- getFluidsInNetwork
          if proxy.getFluidsInNetwork then
            local ok_fl, fluids = pcall(proxy.getFluidsInNetwork)
            if ok_fl and type(fluids) == "table" then
              w("  getFluidsInNetwork(): %d results", #fluids)
              if #fluids > 0 then
                local ex = fluids[1]
                w("    Example: name=%s amount=%s",
                  tostring(ex.name or ex.label), tostring(ex.amount))
              end
            else
              w("  getFluidsInNetwork(): ERROR — %s", tostring(fluids))
            end
          end
          -- setInterfaceConfiguration
          if proxy.setInterfaceConfiguration then
            w("  setInterfaceConfiguration(slot, dbAddress, dbSlot, count?) — configures item stocking")
            w("  setInterfaceConfiguration(slot) — clears item config")
          end
          -- setFluidInterfaceConfiguration
          if proxy.setFluidInterfaceConfiguration then
            w("  setFluidInterfaceConfiguration(side, dbAddress, dbSlot) — configures fluid stocking")
            w("  setFluidInterfaceConfiguration(side) — clears fluid config")
          end
          -- store
          if proxy.store then
            w("  store(filter, dbAddress, dbSlot, count) — samples item to database")
          end
        end

        if ctype == "transposer" or ctype == "adapter" or ctype == "inventory_controller" then
          w("")
          w("  --- %s detail ---", ctype)
          if proxy.getInventorySize then
            for test_side = 0, 5 do
              local ok_sz, sz = pcall(proxy.getInventorySize, test_side)
              if ok_sz and type(sz) == "number" and sz > 0 then
                w("  getInventorySize(%d): %d", test_side, sz)
                -- Sample first few slots
                local parts = {}
                for slot = 1, math.min(sz, 4) do
                  local ok_st, st = pcall(proxy.getStackInSlot, test_side, slot)
                  if ok_st and type(st) == "table" then
                    parts[#parts + 1] = string.format("%sx%d", tostring(st.name), st.size or 0)
                  end
                end
                if #parts > 0 then
                  w("    Sample slots: %s", table.concat(parts, ", "))
                end
              end
            end
          end
          -- Fluid methods
          if proxy.getTankLevel then
            for test_side = 0, 5 do
              local ok_lvl, lvl = pcall(proxy.getTankLevel, test_side)
              if ok_lvl and type(lvl) == "number" and lvl > 0 then
                w("  getTankLevel(%d): %d", test_side, lvl)
              end
            end
          end
          if proxy.getFluidInTank then
            for test_side = 0, 5 do
              local ok_fl, fl = pcall(proxy.getFluidInTank, test_side)
              if ok_fl and type(fl) == "table" then
                if fl.amount then
                  w("  getFluidInTank(%d): name=%s amount=%d",
                    test_side, tostring(fl.name or fl.label or "?"), fl.amount or 0)
                elseif #fl > 0 then
                  w("  getFluidInTank(%d): %d tanks", test_side, #fl)
                  for i, t in ipairs(fl) do
                    if t.amount and t.amount > 0 then
                      w("    [%d] %s = %d", i, tostring(t.name or t.label or "?"), t.amount)
                    end
                  end
                end
              end
            end
          end
          -- transferItem
          if proxy.transferItem then
            w("  transferItem(fromSide, toSide, count, fromSlot, toSlot?)")
          end
        end

        if ctype == "database" then
          w("")
          w("  --- database detail ---")
          local db_slots = 25
          for slot = 1, math.min(db_slots, 80) do
            local ok_entry, entry = pcall(proxy.get, slot)
            if ok_entry and type(entry) == "table" and entry.name then
              w("  slot %d: name=%s damage=%s label=%s size=%s",
                slot, tostring(entry.name), tostring(entry.damage or 0),
                tostring(entry.label or ""), tostring(entry.size or 1))
            end
          end
          w("  get(slot) — read entry")
          w("  set(slot, descriptor) — write entry")
          w("  clear(slot) — clear slot")
        end

        if ctype == "gt_machine" then
          w("")
          w("  --- gt_machine detail ---")
          local methods_to_test = {
            "isWorkAllowed", "isMachineActive", "hasWork",
            "getWorkProgress", "getWorkMaxProgress", "getSensorInformation",
          }
          for _, m in ipairs(methods_to_test) do
            if proxy[m] then
              local ok_val, val = pcall(proxy[m])
              if ok_val then
                w("  %s(): %s", m, tostring(val):sub(1, 200))
              else
                w("  %s(): ERROR — %s", m, tostring(val))
              end
            end
          end
          -- getSensorInformation detail
          if proxy.getSensorInformation then
            local ok_s, sensor = pcall(proxy.getSensorInformation)
            if ok_s and type(sensor) == "table" then
              local sensor_keys = {}; for k in pairs(sensor) do sensor_keys[#sensor_keys+1]=k end
              w("  Sensor info keys: %s", table.concat(sensor_keys, ", "))
            end
          end
        end

        if ctype == "redstone" then
          w("")
          w("  --- redstone detail ---")
          if proxy.setOutput then
            w("  setOutput(side, value) — set redstone output (0-15)")
          end
          if proxy.getOutput then
            for s = 0, 5 do
              local ok_v, v = pcall(proxy.getOutput, s)
              if ok_v then w("  getOutput(%d): %s", s, tostring(v)) end
            end
          end
          if proxy.getInput then
            for s = 0, 5 do
              local ok_v, v = pcall(proxy.getInput, s)
              if ok_v then w("  getInput(%d): %s", s, tostring(v)) end
            end
          end
        end

        if ctype == "modem" then
          w("")
          w("  --- modem detail ---")
          if proxy.open then
            w("  open(port) — open port")
          end
          if proxy.close then
            w("  close(port) — close port")
          end
          if proxy.send then
            w("  send(address, port, payload) — send message")
          end
          if proxy.isOpen then
            for p = 100, 110 do
              local ok_op, op = pcall(proxy.isOpen, p)
              if ok_op and op then w("  port %d: OPEN", p) end
            end
          end
          if proxy.getStrength then
            local ok_s, s = pcall(proxy.getStrength)
            if ok_s then w("  getStrength(): %s", tostring(s)) end
          end
        end

        w("")
      end
      break  -- only first instance per type
    end
  end
end

-- ── All component addresses ─────────────────────────────────────────
w("=== ALL COMPONENT ADDRESSES ===")
w("")
w("(format: type = uuid)")
for addr, ctype in pairs(list) do
  w("  %s = %s", ctype, addr)
end

out:close()
w = nil
print("Done. Output: /home/api_reference.txt")
