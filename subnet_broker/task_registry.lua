--[[
  AutoOS — Task registry (wake name constants)
  Single source of truth for scheduler task names.
  ponytail: string constants add a require for zero runtime benefit,
  but prevent typo bugs across modules.  Keep it <= 10 lines.
]]
return {
  CENTRAL_DISPATCH      = "central_dispatch",
  MACHINE_POLL          = "machine_poll",
  COMPONENT_EVENTS      = "component_events",
  CENTRAL_INPUT_EVENTS  = "central_input_events",
  LANE_PREFIX           = "lane_",
}
