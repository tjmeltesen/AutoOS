--[[
  AutoOS — ROB Dispatcher constants
  Single source of truth for state enums and resource key prefixes.
]]
return {
  FLUID_DROP_ITEM = "ae2fc:fluid_drop",

  -- Buffer monitor states
  DIS_IDLE = "idle",
  DIS_STABILIZING = "stabilizing",

  -- Lane states
  LANE_IDLE = "IDLE",
  LANE_WORKING = "WORKING",
  LANE_FAULTED = "FAULTED",

  -- Resource key prefixes
  RESOURCE_PREFIX_INTERFACE = "interface:",
  RESOURCE_PREFIX_TP = "tp:",
}
