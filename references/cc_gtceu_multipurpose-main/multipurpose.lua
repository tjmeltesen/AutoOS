local runmodes = {
    DEFAULT = 0,
    SINGLE = 1,
    BENCH_INIT = 2,
}
local mode = runmodes.DEFAULT

local args = { ... }
local argPairs = {} -- "key=value" pairs
for _, arg in ipairs(args) do
    local key, value = string.match(arg, "(%w+)=(%w+)")
    if key ~= nil then
        argPairs[key] = value
    else
        argPairs[arg] = true
    end
end

for key, value in pairs(argPairs) do
    if key == "mode" then
        if value == "single" then
            mode = runmodes.SINGLE
            print("Running in single mode")
        elseif value == "benchinit" then
            mode = runmodes.BENCH_INIT
            print("Running in benchinit mode")
        else
            print("Unknown mode " .. value)
            return
        end
    elseif key == "help" then
        print("Usage: multipurpose [help] [mode=single|benchinit]")
        return
    else
        print("Unknown argument " .. key .. ". Use `multipurpose help` for help.")
        return
    end
end

local states = {
    INIT = 0,
    WAITING_FOR_INPUT = 1,
    TRANSFERRING = 2,
    WAITING_FOR_OUTPUT = 3
}

--- Recursively searches for a file within a given directory path.
--- @param path string The directory path where the file is to be searched.
--- @param name string The name of the file to find.
--- @return string|nil Returns the full path to the file if found, or nil if not found.
local function findFileRecursive(path, name)
    local files = fs.list(path)
    for _, file in ipairs(files) do
        if fs.isDir(file) then
            local result = findFileRecursive(file, name)
            if result ~= nil then
                return result
            end
        else
            if file == name then
                return fs.combine(path, file)
            end
        end
    end
    return nil
end

--- Loads the configuration file named 'config.lua' from the current directory or subdirectories.
--- @return table The loaded Lua table from the configuration file.
--- @error Raises an error if the configuration file cannot be found or loaded.
local function loadConfig()
    local configPath = findFileRecursive(".", "config.lua")
    if configPath == nil then
        error("Could not find config.lua")
    end

    -- trim .lua
    configPath = configPath:sub(1, -5)
    print("Loading config from " .. configPath)

    return require(configPath)
end

local config = loadConfig()
if config == nil then
    error("Could not load config.")
end
print("Config loaded")

--- Represents a utility for handling parallel function execution.
PARALLELCALLER = {
    funcs = nil
}

function PARALLELCALLER:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.funcs = {}
    return o
end

--- Enqueues a function to be executed in parallel.
--- @param func function The function to enqueue.
function PARALLELCALLER:enqueue(func)
    table.insert(self.funcs, func)
end

--- Executes all enqueued functions in parallel and clears the queue.
function PARALLELCALLER:call()
    parallel.waitForAll(unpack(self.funcs))
    self.funcs = {}
end

--- Returns the number of functions currently enqueued.
--- @return number The number of enqueued functions.
function PARALLELCALLER:len()
    return #self.funcs
end

--- Output utility for logging and error handling, configurable to write to a file.
OUT = {
    file = nil,
    level = config.logLevel,
}

function OUT:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if config.writeLogToFile then
        o.file = io.open("log.txt", "w")
    end
    return o
end

--- Internal method to write a log message if it meets the level threshold.
--- @param level number The log level of the message.
--- @param msg string The message to log.
function OUT:_write(level, msg)
    if level >= self.level then
        if config.writeLogToFile then
            self.file:write(msg .. "\n")
            self.file:flush()
        end
        print(msg)
    end
end

--- Formats and logs a message with a given level and format string.
--- @param level number The log level for this message.
--- @param fmt string The format string.
--- @param ... vararg Additional arguments for the format string.
function OUT:print(level, fmt, ...)
    if level < self.level then
        return
    end
    local timeStr = os.date("[%d/%m %H:%M:%S] ")
    local msg = timeStr
    if level == config.levels.DEBUG then
        msg = msg .. "D> "
    elseif level == config.levels.INFO then
        msg = msg .. "I> "
    elseif level == config.levels.WARNING then
        msg = msg .. "W> "
    elseif level == config.levels.ERROR then
        msg = msg .. "E> "
    end

    msg = msg .. string.format(fmt, ...)

    self:_write(level, msg)
    if level == config.levels.ERROR then
        error(msg)
    end
end

--- Convenience methods for logging at specific levels.

function OUT:debug(fmt, ...)
    self:print(config.levels.DEBUG, fmt, ...)
end

function OUT:info(fmt, ...)
    self:print(config.levels.INFO, fmt, ...)
end

function OUT:warning(fmt, ...)
    self:print(config.levels.WARNING, fmt, ...)
end

--- Logs an error message and stops execution by throwing an error.
--- @param fmt string The format string for the error message.
--- @vararg any Additional arguments for the format string.
function OUT:error(fmt, ...)
    self:print(config.levels.ERROR, fmt, ...)
end

local out = OUT:new()

--- Formats a table into a string representation.
--- @param tabl table The table to format.
--- @return string A string representation of the table.
function FormatTable(tabl)
    if tabl == nil then
        return "nil"
    end
    local text = ""
    for key, value in pairs(tabl) do
        text = text .. string.format("%s=%s, ", key, value)
    end

    if text ~= "" then
        text = text:sub(1, -3)
    else
        text = "(empty tabl)"
    end

    return text
end

-- END Console

local function checkConfig()
    if config.inputBlockFluids == nil and config.inputBlockItems == nil then
        out:error("At least one of config.inputBlockFluids or config.inputBlockItems must be set")
    end
    if config.outputBlockFluids == nil and config.outputBlockItems == nil then
        out:error("At least one of config.outputBlockFluids or config.outputBlockItems must be set")
    end

    if config.setCircuitConfig and config.circuitReturnInventoryBlock == nil then
        out:error("If config.setCircuitConfig is set to true, config.circuitReturnInventoryBlock must be set")
    end

    if config.outputPairing and (config.outputFluidsPairingCoords.x == nil or config.outputFluidsPairingCoords.y == nil or config.outputFluidsPairingCoords.z == nil) then
        out:error("If config.outputPairing is set to true, config.outputFluidsPairingCoords must be set")
    end

    out:info("Config check passed")
end

checkConfig()

-- GTCEU blocks are often updated (i.e. when an item is inserted/etc), and if we try to call a method while it's updating, the method will fail.
-- so I'm introducing a retry mechanism
local RTR_CNT = 60
--- Calls a Lua function with a specified number of retries on failure.
--- @param func function The function to call.
--- @param retries number The number of retries.
--- @vararg any The arguments to pass to the function.
--- @return any The result of the function call if successful.
local function pcallWithRetries(func, retries, ...)
    if func == nil then
        local info = debug.getinfo(2)
        out:error("Function is nil. Called from %s:%d", info.source, info.currentline)
    end

    local tries = 0
    local last_error = nil
    while tries < retries do
        local succ, msg = pcall(func, ...)
        if succ then
            return msg
        else
            tries = tries + 1
            last_error = msg
        end
    end

    local info = debug.getinfo(2)

    out:error("Max retries (%d) exceeded while calling function %s:%d. Last error: %s", retries, info.source,
            info.currentline, last_error)
end

--- A simplified pcall function with a fixed retry count.
--- @param func function The function to call.
--- @vararg any The arguments to pass to the function.
--- @return any The result of the function call if successful.
local function pcallR(func, ...)
    return pcallWithRetries(func, RTR_CNT, ...)
end

--- Checks if a table contains a specific element.
--- @param table table The table to check.
--- @param element any The element to look for.
--- @return boolean Returns true if the element is found, false otherwise.
function table.contains(table, element)
    for _, value in pairs(table) do
        if value == element then
            return true
        end
    end
    return false
end

local next = next

--- Checks if a table is empty.
--- @param tbl table The table to check.
--- @return boolean Returns true if the table is empty, false otherwise.
function isTableEmpty(tbl)
    if tbl == nil then
        return true
    end
    for _ in pairs(tbl) do
        return false
    end
    return true
end

OUTPUT = {
    items_peripheral = nil,
    items_peripheral_name = nil,
    items_peripheral_coords = nil,

    fluids_peripheral = nil,
    fluids_peripheral_name = nil,
    fluids_peripheral_coords = nil,

    -- cache checks, done by main loop, to reduce calls from statistics loop, which is less important
    last_empty = true,
    last_check = 0
}

--- Creates a new instance of OUTPUT.
--- @return OUTPUT A new OUTPUT object instance.
function OUTPUT:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Sets the item peripheral for the output.
--- @param periph table The peripheral object for items.
function OUTPUT:setItemsPeripheral(periph)
    self.items_peripheral = periph
    self.items_peripheral_name = peripheral.getName(periph)
    self.items_peripheral_coords = pcallR(periph.getCoords)
end

-- Sets the fluid peripheral for the output.
--- @param periph table The peripheral object for fluids.
function OUTPUT:setFluidsPeripheral(periph)
    self.fluids_peripheral = periph
    self.fluids_peripheral_name = peripheral.getName(periph)
    self.fluids_peripheral_coords = pcallR(periph.getCoords)
end

function OUTPUT:_setLastEmpty(val)
    self.last_empty = val
    self.last_check = os.clock()
end

--- Checks if the output is empty, i.e., no items or fluids are queued.
--- @return boolean Returns true if the output is empty, false otherwise.
function OUTPUT:isEmpty()
    if self.fluids_peripheral ~= nil then
        if not isTableEmpty(pcallR(self.fluids_peripheral.tanks)) then
            self:_setLastEmpty(false)
            return false
        end
    end
    if self.items_peripheral ~= nil then
        local items = pcallR(self.items_peripheral.list)
        for _, item in pairs(items) do
            if item.name ~= "gtceu:programmed_circuit" then
                -- ignore circuit configuration "item".
                self:_setLastEmpty(false)
                return false
            end
        end
    end
    self:_setLastEmpty(true)
    return true
end

function OUTPUT:isEmptyCached(delta)
    if os.clock() - self.last_check < delta then
        return self.last_empty
    end
    return self:isEmpty()
end

--- Generates a string representation including coordinates for item and fluid peripherals.
--- @return string A string that represents the current state of both item and fluid peripherals with their coordinates.
function OUTPUT:strWithCoords()
    if self.items_peripheral ~= nil and self.fluids_peripheral ~= nil then
        return string.format("Items: %s, Fluids: %s", FormatTable(self.items_peripheral_coords),
                FormatTable(self.fluids_peripheral_coords))
    elseif self.items_peripheral ~= nil then
        return string.format("Items: %s", FormatTable(self.items_peripheral_coords))
    elseif self.fluids_peripheral ~= nil then
        return string.format("Fluids: %s", FormatTable(pcallR(self.fluids_peripheral.getCoords)))
    end
end

--- Generates a string representation of item peripherals including their coordinates.
--- @return string A string that represents the current state of the item peripherals with their coordinates.
function OUTPUT:itemStrWithCoords()
    if self.items_peripheral ~= nil then
        return string.format("Items: %s", FormatTable(self.items_peripheral_coords))
    end
end

--- Generates a string representation of fluid peripherals including their coordinates.
--- @return string A string that represents the current state of the fluid peripherals with their coordinates.
function OUTPUT:fluidStrWithCoords()
    if self.fluids_peripheral ~= nil then
        return string.format("Fluids: %s", FormatTable(self.fluids_peripheral_coords))
    end
end

--- Encapsulates operations and state management for connected peripherals in the system.
ConnectedPeripherals = {
    circuitReturnInventoryPerihperal = nil,
    circuitReturnInventoryPerihperalName = nil,
    inputBlockFluidsPeripheral = nil,
    inputBlockFluidsPeripheralName = nil,
    inputBlockItemsPeripheral = nil,
    inputBlockItemsPeripheralName = nil,
    outputs = nil,
    monitorPeriph = nil,
    monitorPeriphSizeX = 0,
    monitorPeriphSizeY = 0,

    state = states.INIT,
    did_pushes = 0,

    lastOutputIndex = 1 -- round-robin. Skips over busy outputs
}

--- Creates a new instance of ConnectedPeripherals.
--- @return ConnectedPeripherals A new ConnectedPeripherals object instance.
function ConnectedPeripherals:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Setters for peripherals

function ConnectedPeripherals:setCircuitReturnInventoryPeripheral(periph)
    self.circuitReturnInventoryPerihperal = periph
    self.circuitReturnInventoryPerihperalName = peripheral.getName(periph)
end

function ConnectedPeripherals:setinputBlockFluidsPeripheral(periph)
    self.inputBlockFluidsPeripheral = periph
    self.inputBlockFluidsPeripheralName = peripheral.getName(periph)
end

function ConnectedPeripherals:setinputBlockItemsPeripheral(periph)
    self.inputBlockItemsPeripheral = periph
    self.inputBlockItemsPeripheralName = peripheral.getName(periph)
end

-- Adds an output to the list of connected peripherals
--- @param output OUTPUT The output object to add.
function ConnectedPeripherals:addOutput(output)
    if output.items_peripheral == nil and output.fluids_peripheral == nil then
        out:error("Output must have at least one peripheral")
    end
    if config.outputPairing and (output.items_peripheral == nil or output.fluids_peripheral == nil) then
        out:error("If config.outputPairing is set to true, output must have both item and fluid peripherals.")
    end

    table.insert(self.outputs, output)
end

--- Initializes the ConnectedPeripherals object and loads all peripherals.

function ConnectedPeripherals:_loadPeripherals()
    local outputItemPeripherals = {}
    local outputFluidPeripherals = {}

    local function checkBlockId(periphName, wrapped, methods)
        local hasgetBlockId = table.contains(methods, "getBlockId")
        if hasgetBlockId then
            local blockId = pcallR(wrapped.getBlockId)
            out:debug("Peripheral %s has block id %s", periphName, blockId)
            if blockId == config.circuitReturnInventoryBlock then
                if self.circuitReturnInventoryPerihperal ~= nil then
                    out:warning("Circuit return inventory block is already set, ignoring %s", periphName)
                else
                    out:debug("Circuit return inventory block found at %s, functions: %s", periphName,
                            FormatTable(methods))
                    self:setCircuitReturnInventoryPeripheral(wrapped)
                end
            end
            if blockId == config.inputBlockFluids then
                if self.inputBlockFluidsPeripheral ~= nil then
                    out:warning("Input block for fluids is already set, ignoring %s", periphName)
                else
                    local suc, _ = pcall(wrapped.tanks)
                    if not suc then
                        out:error("Fluid Peripheral %s does not have tanks method", periphName)
                    end
                    self:setinputBlockFluidsPeripheral(wrapped)
                end
            end
            if blockId == config.inputBlockItems then
                if self.inputBlockItemsPeripheral ~= nil then
                    out:warning("Input block for items is already set, ignoring %s", periphName)
                else
                    local suc, _ = pcall(wrapped.list)
                    if not suc then
                        out:error("Item Peripheral %s does not have list method", periphName)
                    end
                    self:setinputBlockItemsPeripheral(wrapped)
                end
            end
            if string.match(blockId, config.outputBlockItems) then
                if config.setCircuitConfig then
                    if not table.contains(methods, "setProgrammedCircuit") then
                        out:error("Peripheral %s does not have setProgrammedCircuit method", periphName)
                    end
                end
                local suc, _ = pcall(wrapped.list)
                if not suc then
                    out:error("Item Peripheral %s does not have list method", periphName)
                end
                table.insert(outputItemPeripherals, wrapped)
                out:debug("Output block for items found at %s", periphName)
            end
            if string.match(blockId, config.outputBlockFluids) then
                local suc, _ = pcall(wrapped.tanks)
                if not suc then
                    out:error("Fluid Peripheral %s does not have tanks method", periphName)
                end
                table.insert(outputFluidPeripherals, wrapped)
                out:debug("Output block for fluids found at %s", periphName)
            end
        else
            if periphName ~= 'back' and periphName ~= 'left' and periphName ~= 'right' and periphName ~= 'top' and periphName ~= 'bottom' then
                out:warning("Peripheral '%s' does not have getBlockId method", periphName)
            end
        end
    end

    local pc = PARALLELCALLER:new()
    for _, periphName_ in pairs(peripheral.getNames()) do
        if peripheral.isPresent(periphName_) then
            pc:enqueue(function()
                local wrapped = peripheral.wrap(periphName_)
                local methods = peripheral.getMethods(periphName_)
                checkBlockId(periphName_, wrapped, methods)
            end)
        end
    end
    pc:enqueue(function()
        local monitor = peripheral.find("monitor")
        if monitor ~= nil then
            self.monitorPeriph = monitor
            out:info("Monitor found!")
            -- TODO: check for size and compare against minimum size
            self.monitorPeriph.clear()
            self.monitorPeriph.setCursorPos(1, 1)
            self.monitorPeriph.write("Found. Time: " .. os.date("%H:%M:%S"))
            self.monitorPeriphSizeX, self.monitorPeriphSizeY = self.monitorPeriph.getSize()
            if self.monitorPeriphSizeX < 40 or self.monitorPeriphSizeY < 7 then
                self.monitorPeriph.write("Monitor size is too small. Minimum size is 40x7")
                out:error("Monitor size is too small. Minimum size is 40x7")
            end
        end
    end)
    pc:call()

    out:info("Loaded peripherals")

    return outputItemPeripherals, outputFluidPeripherals
end

function ConnectedPeripherals:_prepareOutputs(outputItemPeripherals, outputFluidPeripherals)
    self.outputs = {}

    out:info("Preparing outputs...")
    if config.outputPairing then
        if #outputItemPeripherals ~= #outputFluidPeripherals then
            out:error("Number of item and fluid peripherals must be equal when config.outputPairing is set to true")
        end

        local function prepareOutput(itemPeriph)
            local output = OUTPUT:new()
            local itemCoodrinates = pcallR(itemPeriph.getCoords)
            local expectedFluidCoords = {
                x = itemCoodrinates.x + config.outputFluidsPairingCoords.x,
                y = itemCoodrinates.y + config.outputFluidsPairingCoords.y,
                z = itemCoodrinates.z + config.outputFluidsPairingCoords.z
            }
            for _, fluidPeriph in ipairs(outputFluidPeripherals) do
                local fluidCoordinates = pcallR(fluidPeriph.getCoords)
                if fluidCoordinates.x == expectedFluidCoords.x and
                        fluidCoordinates.y == expectedFluidCoords.y and
                        fluidCoordinates.z == expectedFluidCoords.z then
                    output:setItemsPeripheral(itemPeriph)
                    output:setFluidsPeripheral(fluidPeriph)
                end
            end
            if output.fluids_peripheral == nil then
                out:error(
                        "Could not find matching fluid peripheral for item peripheral at coordinates %s. Expected fluid peripheral at coordinates %s",
                        FormatTable(itemCoodrinates), FormatTable(expectedFluidCoords)
                )
            end
            self:addOutput(output)
        end

        local pc = PARALLELCALLER:new()
        for _, itemPeriph_ in ipairs(outputItemPeripherals) do
            pc:enqueue(function()
                prepareOutput(itemPeriph_)
            end)
        end
        pc:call()
    else
        local function prepareOutput(itemPeriph)
            local output = OUTPUT:new()
            output:setItemsPeripheral(itemPeriph)
            self:addOutput(output)
        end

        local pc = PARALLELCALLER:new()
        for _, itemPeriph in ipairs(outputItemPeripherals) do
            pc:enqueue(function()
                prepareOutput(itemPeriph)
            end)
        end
        pc:call()

        pc = PARALLELCALLER:new()
        for _, fluidPeriph in ipairs(outputFluidPeripherals) do
            pc:enqueue(function()
                local output = OUTPUT:new()
                output:setFluidsPeripheral(fluidPeriph)
                self:addOutput(output)
            end)
        end
        pc:call()
    end

    out:info("Outputs prepared")
end

function ConnectedPeripherals:_checkPeripherals()
    if self.circuitReturnInventoryPerihperal == nil then
        if config.setCircuitConfig then
            out:error(
                    "Circuit return inventory block not found. Please make sure that config.circuitReturnInventoryBlock is set correctly")
        end
    else
        out:info("Circuit return inventory block found at %s",
                FormatTable(pcallR(self.circuitReturnInventoryPerihperal.getCoords)))
    end

    if self.inputBlockFluidsPeripheral == nil then
        if config.inputBlockFluids ~= nil then
            out:error("Input block for fluids not found. Please make sure that config.inputBlockFluids is set correctly")
        end
    else
        out:info("Input block for fluids found at %s", FormatTable(pcallR(self.inputBlockFluidsPeripheral.getCoords)))
    end

    if self.inputBlockItemsPeripheral == nil then
        if config.inputBlockItems ~= nil then
            out:error("Input block for items not found. Please make sure that config.inputBlockItems is set correctly")
        end
    else
        out:info("Input block for items found at %s", FormatTable(pcallR(self.inputBlockItemsPeripheral.getCoords)))
    end

    -- make sure no outputs are duplicated
    local outputItemCoords = {}
    local outputFluidCoords = {}
    for _, output in ipairs(self.outputs) do
        if output.items_peripheral ~= nil then
            local coords = pcallR(output.items_peripheral.getCoords)
            if outputItemCoords[coords] ~= nil then
                out:error("Output item peripheral at %s is duplicated", FormatTable(coords))
            end
        end
        if output.fluids_peripheral ~= nil then
            local coords = pcallR(output.fluids_peripheral.getCoords)
            if outputFluidCoords[coords] ~= nil then
                out:error("Output fluid peripheral at %s is duplicated", FormatTable(coords))
            end
        end
    end

    if #self.outputs == 0 then
        out:error(
                "No output blocks found. Please make sure that config.outputBlockItems and config.outputBlockFluids are set correctly")
    else
        out:info("Found %d output blocks/pairs", #self.outputs)
        for i, output in ipairs(self.outputs) do
            out:info("Output block %d found: %s", i, output:strWithCoords())
        end
    end
end

function ConnectedPeripherals:initialize()
    local outputItemPeripherals, outputFluidPeripherals = self:_loadPeripherals()
    self:_prepareOutputs(outputItemPeripherals, outputFluidPeripherals)
    self:_checkPeripherals()
    out:info("Initialization complete")
end

--- Finds an available output peripheral using a round-robin method.
--- @return table|nil Returns the available output or nil if none is found.
function ConnectedPeripherals:findAvailableOutputRR()
    local startIndex = self.lastOutputIndex + 1
    -- Wrap the start index if it exceeds the number of outputs
    if startIndex > #self.outputs then
        startIndex = 1
    end

    -- First, try to find an available output starting from startIndex to the end of the list
    for i = startIndex, #self.outputs do
        if self.outputs[i]:isEmpty() then
            out:debug("Output %d (%s) is available", i, self.outputs[i]:strWithCoords())
            self.lastOutputIndex = i
            return self.outputs[i]
        end
    end

    -- If no output was found in the first part, try from the beginning of the list to startIndex - 1
    for i = 1, startIndex - 1 do
        if self.outputs[i]:isEmpty() then
            out:debug("Output %d (%s) is available", i, self.outputs[i]:strWithCoords())
            self.lastOutputIndex = i
            return self.outputs[i]
        end
    end

    -- Return nil if no available output is found
    return nil
end

--- Finds an available output peripheral without specific ordering.
--- @return table|nil Returns the available output or nil if none is found.
function ConnectedPeripherals:findAvailableOutputSimple()
    for i, output in ipairs(self.outputs) do
        if output:isEmpty() then
            out:debug("Output %d (%s) is available", i, output:strWithCoords())
            return output
        end
    end

    return nil
end

--- Selects an available output based on configuration.
--- @return table|nil Returns the available output or nil if none is found.
function ConnectedPeripherals:findAvailableOutput()
    if config.doRoundRobin then
        return self:findAvailableOutputRR()
    else
        return self:findAvailableOutputSimple()
    end
end

--- Pushes items from the input block to a target peripheral.
--- @param target OUTPUT The target output.
function ConnectedPeripherals:pushItems(target)
    if target.items_peripheral == nil then
        return
    end
    local itemList = pcallR(self.inputBlockItemsPeripheral.list)
    local pc = PARALLELCALLER:new()
    local needsToBePushed = nil
    for i, item in pairs(itemList) do
        needsToBePushed = true

        out:debug("Checking pushItems: %d %s", item.count, item.name, target:itemStrWithCoords())

        if config.setCircuitConfig and item.name == config.circuitConfigItem then
            out:debug("This is a circuit configuration item")
            -- we need to parse displayName and extract the number, if it's in format "C:{number}"
            local itemDetails = pcallR(self.inputBlockItemsPeripheral.getItemDetail, i)
            local numberStr = string.match(itemDetails.displayName, "C:(%-?%d+)")
            if numberStr ~= nil then
                local number = tonumber(numberStr)
                if number < -1 or number > 32 then
                    out:error("Circuit configuration number %s is out of range [-1, 32]", number)
                end
                out:debug("Enqueuing push")
                pc:enqueue(function()
                    pcallR(self.inputBlockItemsPeripheral.pushItems, self.circuitReturnInventoryPerihperalName, i)
                end)
                pcallR(target.items_peripheral.setProgrammedCircuit, number)
                out:debug("Circuit configuration set to %d", number)
                needsToBePushed = false
            else
                out:warning(
                        "Could not parse circuit configuration number from item %s (%s), treating it as a regular item",
                        item.name, itemDetails.displayName)
            end
        end

        if needsToBePushed then
            out:debug("Item %d %s queud to be pushed to %s", item.count, item.name, target:itemStrWithCoords())
            pc:enqueue(function()
                out:debug("Pushing %d %s to %s", item.count, item.name, target:itemStrWithCoords())
                pcallR(self.inputBlockItemsPeripheral.pushItems, target.items_peripheral_name, i)
                out:debug("Item %d %s pushed to %s", item.count, item.name, target:itemStrWithCoords())
            end)
        end

    end
    out:debug("Calling %d queued item pushes", pc:len())
    pc:call()
end

--- Pushes fluids from the input block to a target peripheral.
--- @param target OUTPUT The target output.
function ConnectedPeripherals:pushFluids(target)
    if target.fluids_peripheral == nil then
        return
    end
    local tankList = pcallR(self.inputBlockFluidsPeripheral.tanks)
    local pc = PARALLELCALLER:new()
    for i, tank in pairs(tankList) do
        pc:enqueue(function()
            out:debug("Pushing %d %s to %s", tank.amount, tank.name, target:fluidStrWithCoords())
            pcallR(self.inputBlockFluidsPeripheral.pushFluid, target.fluids_peripheral_name, i)
            out:debug("Fluid %d %s pushed to %s", tank.amount, tank.name, target:fluidStrWithCoords())
        end)
    end
    out:debug("Calling %d queued fluid pushes", pc:len())
    pc:call()
end

--- Pushes both items and fluids from the input blocks to a target peripheral.
--- @param target OUTPUT The target output.
function ConnectedPeripherals:pushAll(target)
    parallel.waitForAll(
            function()
                self:pushItems(target)
            end,
            function()
                self:pushFluids(target)
            end
    )
end

--- Checks if there are items in the input block.
--- @return boolean Returns true if items are present, false otherwise.
function ConnectedPeripherals:hasItemsInInput()
    return not isTableEmpty(pcallR(self.inputBlockItemsPeripheral.list))
end

--- Checks if there are fluids in the input block.
--- @return boolean Returns true if fluids are present, false otherwise.
function ConnectedPeripherals:hasFluidsInInput()
    return not isTableEmpty(pcallR(self.inputBlockFluidsPeripheral.tanks))
end

function ConnectedPeripherals:loop(stopAfterOne)
    if config.outputPairing then
        while true do
            if self:hasItemsInInput() or self:hasFluidsInInput() then
                local output = self:findAvailableOutput()
                if output ~= nil then
                    out:debug("========= Next push =========")
                    self.state = states.TRANSFERRING
                    self:pushAll(output)
                    self.did_pushes = self.did_pushes + 1
                    self.state = states.WAITING_FOR_INPUT
                    out:debug("========= Push complete =========")
                else
                    out:warning("No available outputs found")
                    self.state = states.WAITING_FOR_OUTPUT
                end
            else
                -- out:debug("No items/fluids in input")
                self.state = states.WAITING_FOR_INPUT
            end

            if stopAfterOne then
                break
            end
        end
    else
        while true do
            if self:hasItemsInInput() then
                local output = self:findAvailableOutput()
                if output ~= nil then
                    out:debug("========= Next push =========")
                    self.state = states.TRANSFERRING
                    self:pushItems(output)
                    self.did_pushes = self.did_pushes + 1
                    self.state = states.WAITING_FOR_INPUT
                    out:debug("========= Push complete =========")
                else
                    out:warning("No available outputs for items found")
                    self.state = states.WAITING_FOR_OUTPUT
                end
            end
            if self:hasFluidsInInput() then
                local output = self:findAvailableOutput()
                if output ~= nil then
                    out:debug("========= Next push =========")
                    self.state = states.TRANSFERRING
                    self:pushFluids(output)
                    self.did_pushes = self.did_pushes + 1
                    self.state = states.WAITING_FOR_INPUT
                    out:debug("========= Push complete =========")
                else
                    out:warning("No available outputs for fluids found")
                    self.state = states.WAITING_FOR_OUTPUT
                end
            end

            if stopAfterOne then
                break
            end
        end
    end
end


--- Draws a progress bar on the monitor at the specified position with the specified width and height.
--- @param x number The x-coordinate of the progress bar start
--- @param y number The y-coordinate of the progress bar start
--- @param barWidth number The width of the progress bar
--- @param progress number The progress value between 0.0 and 1.0
function ConnectedPeripherals:drawProgressBar(x, y, barWidth, progress)
    self.monitorPeriph.setCursorPos(x, y)
    local maxLen = self.monitorPeriphSizeX - x - (1 * 2)
    if barWidth > maxLen then
        barWidth = maxLen
    end

    local greenPartLen = math.floor((barWidth * progress))
    local redPartLen = barWidth - greenPartLen
    self.monitorPeriph.setBackgroundColor(colors.green)
    self.monitorPeriph.write(string.rep(" ", greenPartLen))

    self.monitorPeriph.setBackgroundColor(colors.red)
    self.monitorPeriph.write(string.rep(" ", redPartLen))

    self.monitorPeriph.setBackgroundColor(colors.black)

end

function ConnectedPeripherals:monitorLoop()
    if self.monitorPeriph == nil then
        return
    end

    local lastRefetch = 0

    local availableOutputs = 0

    local availableOutputsItem = 0
    local availableOutputsFluid = 0

    local totalOutputs = 0
    local totalOutputsItem = 0
    local totalOutputsFluid = 0
    local toWriteOutputs = nil

    local startedAt = os.clock()
    local progBarX = 0

    while true do
        if (os.clock() - lastRefetch) > 1 then
            availableOutputs = 0
            availableOutputsItem = 0
            availableOutputsFluid = 0
            totalOutputsItem = 0
            totalOutputsFluid = 0

            local pc = PARALLELCALLER:new()
            for _, output in pairs(self.outputs) do
                pc:enqueue(function()
                    if output:isEmptyCached(1) then
                        availableOutputs = availableOutputs + 1
                        if output.items_peripheral ~= nil then
                            availableOutputsItem = availableOutputsItem + 1
                            totalOutputsItem = totalOutputsItem + 1
                        end
                        if output.fluids_peripheral ~= nil then
                            availableOutputsFluid = availableOutputsFluid + 1
                            totalOutputsFluid = totalOutputsFluid + 1
                        end
                    end
                end)
            end

            pc:call()

            totalOutputs = #self.outputs
            lastRefetch = os.clock()
        end

        self.monitorPeriph.clear()
        self.monitorPeriph.setCursorPos(1, 1)
        self.monitorPeriph.write("Time: " .. os.date("%H:%M:%S") .. " (running for " .. math.floor(os.clock() - startedAt) .. "s)")
        self.monitorPeriph.setCursorPos(1, 2)
        if self.state == states.INIT then
            self.monitorPeriph.write("State: Initializing")
        elseif self.state == states.WAITING_FOR_INPUT then
            self.monitorPeriph.write("State: Waiting for input")
        elseif self.state == states.WAITING_FOR_OUTPUT then
            self.monitorPeriph.write("State: Waiting for output")
        elseif self.state == states.TRANSFERRING then
            self.monitorPeriph.write("State: Transferring")
        else
            self.monitorPeriph.write("State: " .. self.state)
        end
        self.monitorPeriph.setCursorPos(1, 3)
        self.monitorPeriph.write("Last output: #" .. self.lastOutputIndex)
        self.monitorPeriph.setCursorPos(1, 4)
        self.monitorPeriph.write("Did pushes: " .. self.did_pushes)
        self.monitorPeriph.setCursorPos(1, 5)
        if config.outputPairing then
            toWriteOutputs = "Outputs: " .. availableOutputs .. "/" .. totalOutputs
        else
            toWriteOutputs = "Outputs: " .. availableOutputsItem .. "/" .. totalOutputsItem .. " (items), " ..
                    availableOutputsFluid .. "/" .. totalOutputsFluid .. " (fluids)"
        end
        self.monitorPeriph.write(toWriteOutputs)
        progBarX = #toWriteOutputs
        if progBarX + (10 + 2) < self.monitorPeriphSizeX then
            self:drawProgressBar(progBarX + 2, 5, self.monitorPeriphSizeX - progBarX - 2, availableOutputs / totalOutputs)
        end
        os.sleep(1.0 / 20.0)
    end
end

function ConnectedPeripherals:run()
    local stopAfterOne = mode == runmodes.SINGLE
    if self.monitorPeriph ~= nil then
        parallel.waitForAny(function()
            self:loop(stopAfterOne)
        end, function()
            self:monitorLoop()
        end)
    else
        self:loop(stopAfterOne)
    end
end

if mode == runmodes.BENCH_INIT then
    out:info("Bench init mode")
    local started = os.epoch("utc")
    local connectedPeripherals = ConnectedPeripherals:new()
    connectedPeripherals:initialize()
    local ended = os.epoch("utc")
    out:info("Initialization took %d ms", ended - started)
    return
end

local connectedPeripherals = ConnectedPeripherals:new()
connectedPeripherals:initialize()

connectedPeripherals:run()