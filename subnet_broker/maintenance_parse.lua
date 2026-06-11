--[[
  AutoOS — GT maintenance sensor parser (subnet broker)

  Pure logic — no hardware calls. Ported from legacy/modules/maintenance.lua.

  References: references/maintenance-and-safety.md
]]

local MaintenanceParse = {}

local function strip_format(s)
  return (s:gsub("\194\167.", ""))
end

MaintenanceParse.strip_format = strip_format

local FAULT_PATTERNS = {
  "has problems",
  "maintenance required",
  "needs repair",
  "needs a hammer",
  "needs a wrench",
  "needs a screwdriver",
  "needs some duct tape",
  "needs a hard hammer",
  "needs a crowbar",
  "incomplete structure",
  "structure is incomplete",
  "structure not formed",
  "structure not complete",
  "invalid structure",
  "structure check failed",
  "structure invalid",
  "not enough blocks",
  "incorrect structure",
}

MaintenanceParse.FAULT_PATTERNS = FAULT_PATTERNS

local function problems_count(line)
  local count = line:match("problems:%s*(%d+)")
  if count then
    return tonumber(count)
  end
  return nil
end

function MaintenanceParse.has_fault(lines)
  if type(lines) ~= "table" then
    return false
  end
  for _, raw in ipairs(lines) do
    local clean = strip_format(raw)
    local lower = clean:lower()

    local count = problems_count(lower)
    if count and count > 0 then
      return true, clean
    end

    for _, pat in ipairs(FAULT_PATTERNS) do
      if lower:find(pat, 1, true) then
        return true, clean
      end
    end
  end
  return false
end

return MaintenanceParse
