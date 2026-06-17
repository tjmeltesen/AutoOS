local levels = {
    DEBUG = 0,
    INFO = 1,
    WARNING = 2,
    ERROR = 3
}

local writeLogToFile = false
local logLevel = levels.INFO

-- if setCircuitConfig is true, any renamed item (circuitConfigItem) in format "C:{number}" will be treated as circuit configuration trigger (and will be immediately returned to the circuitReturnInventoryBlock)
local setCircuitConfig = true
local circuitConfigItem = "minecraft:paper"         -- item that will be used to set circuit configuration
local circuitReturnInventoryBlock = "ae2:interface" -- where to return circuit configuration items

-- input in this context means FROM WHERE will items/fluids be extracted, i.e. a chest and a fluid cell
local inputBlockFluids = "expatternprovider:ingredient_buffer" -- from where will fluids be extracted
local inputBlockItems = "expatternprovider:ingredient_buffer"  -- from where will items be extracted

-- output in this context means WHERE will items/fluids be inserted, i.e. a GTCEU input hatch and a GTCEU input bus
local outputBlockFluids =
"^gtceu:.*input_hatch.*$" -- where will fluids be inserted (in this case - any gtceu input hatch)
local outputBlockItems =
"^gtceu:.*input_bus.*$" -- where will items be inserted (in this case - any gtceu input bus)


local outputPairing = true -- if true, instead of treating all output blocks as separate, they will be treated as pairs (i.e. 1 liquid hatch and 1 item bus, useful for EBFs)
-- if outputPairing is set to true, then these deltas will be used to calculate the position of the `outputBlockFluids` relative to the `outputBlockItems`, i.e.
-- if you have a bus and a hatch 3 blocks above, you should set the deltas to x=0, y=3, z=0
local outputFluidsPairingCoords = {
    x = 0,
    y = 0,
    z = 0
}

local doRoundRobin = true -- if true, the system will try to distribute items in a round-robin fashion, i.e. try index 2 if previous index was 1, etc.

local cfg = {
    levels = levels,
    writeLogToFile = writeLogToFile,
    logLevel = logLevel,
    setCircuitConfig = setCircuitConfig,
    circuitConfigItem = circuitConfigItem,
    circuitReturnInventoryBlock = circuitReturnInventoryBlock,
    inputBlockFluids = inputBlockFluids,
    inputBlockItems = inputBlockItems,
    outputBlockFluids = outputBlockFluids,
    outputBlockItems = outputBlockItems,
    outputPairing = outputPairing,
    outputFluidsPairingCoords = outputFluidsPairingCoords,
    doRoundRobin = doRoundRobin
}

return cfg
