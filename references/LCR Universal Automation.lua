-- Per Lane Automation for LCR



local c = require("component")
local s = require("sides")
local os = require("os")
local term = require("term")
 
local machine_name = "LCR"
local s_buffer = s.east
local s_machine = s.north
local s_circuit = s.up
local chest_slot_start = 5 -- quad drawers start at 5, vanilla chests at 1
 
-- Wrap the transposers with a proxy for easier method calls
local transposers = {}
for address, name in c.list("transposer") do
  table.insert(transposers, c.proxy(address))
end
 
local hatch = nil
local bus = nil
 
-- MAIN LOOP
while true do
  term.clear()
 
  print("Watching for buffered inputs...")
  while true do
    local found = false
    for i_t, t in ipairs(transposers) do 
      local tanks = t.getTankCount(s_buffer)
 
      if tanks > 0 and t.getTankLevel(s_buffer, 1) > 0 then
        found = true
      end
      if tanks == 0 and t.getSlotStackSize(s_buffer, chest_slot_start) > 0 then
        found = true
      end
    end
 
    -- Any inputs break us from this loop
    if found then
      break
    end
    os.sleep(0.25)
  end
 
  print("> Inputs found... Time to work!")
 
  -- We delay for a few ticks to make sure that AE2 gave us everything
  os.sleep(0.1)
 
  print(machine_name .. " Locked")
  print("Moving inputs from the buffer to the " .. machine_name .. "...")
 
  for i_t, t in ipairs(transposers) do
    local tanks = t.getTankCount(s_buffer)
 
    -- Move the fluids from the buffer to the machine
    if tanks > 0 then
      hatch = t
      for i = 1, t.getTankCount(s_buffer), 1 do
        local success, msg = t.transferFluid(s_buffer, s_machine, 1000000)
        -- NOTE: we cannot target specific tanks by slot number, we just have to try until we fail
        if success == false then
          break
        else
          print("> Transfered " .. msg .. " fluids")
        end
      end
    end
 
    -- Move the circuit and other input items from the buffer to the machine
    if tanks == 0 then
      bus = t
      for i = chest_slot_start, t.getInventorySize(s_buffer), 1 do
        local size = t.getSlotStackSize(s_buffer, i)
        if size > 0 then
          local result = t.transferItem(s_buffer, s_machine, size, i)
          print("> Transfered " .. size .. " items from slot " .. i)
        end
      end
    end
  end
 
  print("Waiting for liquids to drain from the " .. machine_name .. "...")
  while true do
    if hatch.getTankLevel(s_machine, 1) == 0 then
      break
    end
    os.sleep(0.25)
  end
 
  print("Waiting for items to drain from the " .. machine_name .. "...")
  while true do
    -- NOTE: By convention, your circuit is in slot 1
    --       This requires you to make sure your patterns are set up this way
    --       If slot 2 is empty, that means we're "empty" of items
    if bus.getSlotStackSize(s_machine, 2) == 0 then
      break
    end
    os.sleep(0.25)
  end
  print("> " .. machine_name .. " is empty and on its last craft.")
 
  -- We know we're almost done, so extract the circuit
  local size = bus.getSlotStackSize(s_machine, 1)
  if size > 0 then
    local result = bus.transferItem(s_machine, s_circuit, size, 1)
    print("Circuit extracted.")
  else
    print("Circuit not found, your pattern is bad! Put it in the first slot!")
  end
 
  -- Wait until AE has the circuit back
  print("Waiting for circuit to import into AE...")
  while true do
    if bus.getSlotStackSize(s_circuit, 1) == 0 then
      print("> Done!")
      break
    end
    os.sleep(0.1)
  end
 
  print(machine_name .. " Unlocked")
  print(" ")
end