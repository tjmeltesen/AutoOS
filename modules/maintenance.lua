--[[
  AutoOS — Maintenance Module (Module 2, Priority 1)

  Pure logic. Reads the State Cache only — performs NO hardware calls.
  Detects GregTech multiblock maintenance faults and structure failures by
  parsing the sensor information strings captured by the adapter, then emits a
  Priority 1 (Critical Safety) shutdown intent for the arbitrator to commit.

  There is no dedicated maintenance boolean in the gt_machine API, so detection
  is done by parsing getSensorInformation() text after stripping Minecraft
  formatting (§) codes.

  References:
    references/maintenance-and-safety.md    (the 6 issues + structure errors)
    references/gt-machine-api.md             (sensor parsing example)
    README.md §3                             (Priority 1 arbitration)
]]

local Maintenance = {}

-- Minecraft formatting codes are "§" followed by one character. In UTF-8 the
-- "§" byte sequence is 0xC2 0xA7, so a single "." after the literal prefix
-- covers the trailing format char.
local function strip_format(s)
  return (s:gsub("\194\167.", ""))
end

Maintenance.strip_format = strip_format

-- Substrings that indicate a maintenance fault or a structure failure.
-- Matched as plain text (case-insensitive) against stripped sensor lines.
local FAULT_PATTERNS = {
  -- maintenance hatch problems
  "problem",
  "maintenance",
  "repair",
  "has problems",
  -- the six specific maintenance issues
  "needs a hammer",
  "needs a wrench",
  "needs a screwdriver",
  "needs some duct tape",
  "needs a hard hammer",
  "needs a crowbar",
  -- structural integrity failures (treated as Priority 1 alongside maintenance)
  "structure",
  "incomplete",
  "invalid",
}

Maintenance.FAULT_PATTERNS = FAULT_PATTERNS

-- Scan an array of sensor lines for any fault pattern.
-- Returns: faulted(boolean), message(string|nil) — the offending (cleaned) line.
function Maintenance.has_fault(lines)
  if type(lines) ~= "table" then
    return false
  end
  for _, raw in ipairs(lines) do
    local clean = strip_format(raw)
    local lower = clean:lower()
    for _, pat in ipairs(FAULT_PATTERNS) do
      if lower:find(pat, 1, true) then
        return true, clean
      end
    end
  end
  return false
end

-- Evaluate the cache and return a Priority 1 intent when a fault is present.
-- Returns nil when the machine is healthy (no intent contributed).
function Maintenance.evaluate(cache)
  local faulted, message = Maintenance.has_fault(cache and cache.sensor)
  if faulted then
    return {
      priority = 1,
      module = "maintenance",
      action = "force_shutdown",
      reason = message,
    }
  end
  return nil
end

return Maintenance
