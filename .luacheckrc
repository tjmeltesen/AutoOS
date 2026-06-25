std = "lua52"

globals = {
    -- OpenComputers runtime globals
    "component", "computer", "event",
    -- OC peripherals
    "term", "robot", "unicode", "filesystem", "serialization",
    -- OC threading
    "thread",
}

read_globals = {
    -- Lua stdlib (luacheck auto-recognizes most, but be explicit for safety)
    "arg",        -- command-line args
    "bit",        -- LuaJIT bit library (OC uses LuaJIT)
    "bit32",      -- Lua 5.2 bit32 compat
    -- Metatable
    "setmetatable", "getmetatable",
    "rawget", "rawset", "rawequal",
    -- Iteration
    "next", "pairs", "ipairs",
    -- Type coercion
    "tonumber", "tostring", "type",
    -- Vararg / unpack
    "select", "unpack",
    -- Error handling
    "error", "assert", "xpcall", "pcall",
    -- Loading
    "load", "loadfile", "dofile",
    -- Output (used pervasively for debugging)
    "print",
    -- Environment
    "_G", "_VERSION",
    -- Module system
    "require",
}

include_files = {
    "subnet_broker/**.lua",
    "orchestrator/**.lua",
    "shared/**.lua",
    "tests/**.lua",
}

exclude_files = {
    "references/**",
    "legacy/**",
    "graphify-out/**",
    -- network_protocols.lua is triplicated for independent deployment;
    -- lint only the canonical copy in shared/
    "subnet_broker/network_protocols.lua",
    "orchestrator/network_protocols.lua",
}

ignore = {
    -- Trailing whitespace -- common in hand-authored Lua
    "611",
    -- Line too long -- OC screens render reports in-game, line length varies by screen resolution
    "614",
}
