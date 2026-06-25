std = "lua52"

globals = {
    -- OpenComputers runtime globals
    "component", "computer", "event",
    -- OC peripherals
    "term", "robot", "unicode", "filesystem", "serialization",
    -- OC threading
    "thread",
    -- Stdlib (always available)
    "os", "io", "math", "string", "table", "coroutine", "debug", "package",
}

read_globals = {
    "arg",
    "bit", "bit32",
    "setmetatable", "getmetatable",
    "rawget", "rawset", "rawequal",
    "next", "pairs", "ipairs",
    "tonumber", "tostring", "type",
    "select", "unpack",
    "error", "assert", "xpcall", "pcall",
    "load", "loadfile", "dofile",
    "print",
    "_G", "_VERSION",
    "require",
    "math", "string", "table", "coroutine", "debug",
}

-- Check everything by default, exclude only third-party and dupes
exclude_files = {
    "references/**",
    "legacy/**",
    "graphify-out/**",
    ".claude/**",
    -- network_protocols.lua is triplicated for independent deployment;
    -- lint only the canonical copy in shared/
    "subnet_broker/network_protocols.lua",
    "orchestrator/network_protocols.lua",
}

ignore = {
    -- Trailing whitespace (common in hand-authored Lua)
    611,
    -- Line too long (OC screens render varying resolutions)
    614,
    -- Accessing undefined field of global (OC runtime extends stdlib)
    143,
    -- Accessing undefined variable (pre-existing lane_completion references)
    113,
    -- Setting read-only global (pre-existing, e.g., print override in find.lua)
    122,
    -- Mutating/setting non-standard global (pre-existing)
    111, 131,
    -- Unused argument / variable / loop variable (pre-existing)
    211, 212, 213,
    -- Value assigned to variable is unused / never accessed
    311,
    -- Shadowing definition / redefining local
    411, 421, 423,
    -- Loop executed at most once
    511,
}
