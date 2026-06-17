# GTCEU multiblock Automation System

### I am not a lua programmer. I am not planning to support this, as it was made for myself. If you want to use it, you are on your own.

## Requirements
- [Cc tweaked](https://modrinth.com/mod/cc-tweaked)
- [Kubejs + cc](https://modrinth.com/mod/kubejs+cc-tweaked)
- [KubeJs](https://modrinth.com/mod/kubejs)
- ofc, the gtceu

## Installation
Install the mods above.

Put files from `startup_scripts` in **{modpack/minecraft folder}**`/kubejs/startup_scripts`


## Overview
This system is designed to automate the process of managing multiple GregTech multiblocks, enabling automatic circuit configuration changes for efficient processing. It leverages Lua scripts to parallelize operations across various peripherals, handling both items and fluids dynamically.

## Features
- **Parallel Processing:** Utilizes multiple GregTech multiblocks in parallel to optimize processing tasks.
- **Dynamic Circuit Configuration:** Automatically changes circuits based on specified configurations to adapt to different operations.
- **Robust Logging:** Supports logging at various levels (DEBUG, INFO, WARNING, ERROR) and can write logs to a file for troubleshooting and monitoring.
- **Flexible Item and Fluid Handling:** Configurable input and output blocks for managing both items and fluids.
- **Round-Robin Distribution:** Optional round-robin approach for distributing items evenly across available outputs.
- **Output Pairing:** Supports pairing of output blocks (e.g., a liquid hatch and an item bus) to coordinate actions on paired peripherals, like multiblocks - Electric Blast Furnaces, Alloy Blast Smelter, etc.

## Configuration
The system's behavior is controlled by a configuration table defined in the Lua script, with the following keys:

- `writeLogToFile`: Toggle to enable or disable writing logs to a file.
- `logLevel`: The current log level, set to DEBUG by default for comprehensive output.
- `setCircuitConfig`: Enables or disables automatic circuit configuration.
- `circuitConfigItem`: Specifies the item used for circuit configuration, defaulting to "minecraft:paper".
- `circuitReturnInventoryBlock`: Defines the block (typically an ME interface) where circuit configuration items are returned after use.
- `inputBlockFluids`: Identifies the block from which fluids are extracted.
- `inputBlockItems`: Identifies the block from which items are extracted.
- `outputBlockFluids`: Regex pattern that matches the blocks into which fluids are inserted.
- `outputBlockItems`: Regex pattern that matches the blocks into which items are inserted.
- `outputPairing`: If set to true, treats output blocks as pairs rather than individually.
- `outputFluidsPairingCoords`: Specifies the relative coordinates for paired fluid and item output blocks.
- `doRoundRobin`: Enables or disables round-robin distribution of items and fluids to output blocks.

## Usage
The system is designed to be used with a ME Pattern Provider that pushes items into an ME Ingredient Buffer in blocking mode. This buffer is then specified as both `inputBlockFluids` and `inputBlockItems`, although separate blocks like a barrel and a fluid cell can also be used.

The `circuitReturnInventoryBlock` is configured as an ME interface where the `circuitConfigItem` is returned after setting a circuit configuration in a multiblock. The automation script takes care of initializing the peripherals, setting up configurations, and handling the operations in a loop to ensure continuous processing.

## Log Levels
The system defines several log levels to control the amount and type of output generated:

- `DEBUG`: Provides detailed debug information.
- `INFO`: General information about operations.
- `WARNING`: Warnings that might indicate a potential issue.
- `ERROR`: Critical issues that require immediate attention.

## Dependencies
This system requires a Lua environment with the `parallel`, `fs`, and `peripheral` APIs available, typically provided in a modded Minecraft setting using the ComputerCraft or similar mods.

## Notes
It is recommended to encode bulk patterns for AE2, since lua and cc isn't the fastest thing in the world.

## Support
For support, refer to the system logs and ensure your modded environment is set up correctly to interface with the Lua script. For further assistance, review the mod documentation or community forums associated with your Minecraft mods.

## Circuit Configuration and Usage

To facilitate dynamic control over circuit configurations in GregTech multiblocks, the system allows encoding of AE2 patterns using an item, typically "minecraft:paper", renamed to indicate the circuit number. Each renamed item should follow the format "C:{number}", where "{number}" represents the circuit number. For example:



- "C:1" sets the device to circuit configuration 1.

- "C:-1" removes any existing circuit configuration.

- "C:20" sets the device to circuit configuration 20.



These items should be set as secondary outputs in the AE2 system to ensure they returned to AE2. The system automatically handles the return of these items to the designated `circuitReturnInventoryBlock` after use, allowing for continuous reuse.



Ensure that these circuit configuration items are encoded into the AE2 patterns correctly and that they are also present in the system to allow seamless automation of your GregTech setups.

Example pattern:
![image](https://github.com/user-attachments/assets/5458e648-ab39-4585-a8d2-023a7fd2d261)

Example setup:
![image](https://github.com/user-attachments/assets/a2c950b9-d734-42b1-8158-f9ed5c5ca3ee)

