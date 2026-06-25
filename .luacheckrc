std = "lua52"

-- Only list globals that are NOT part of lua52 std (i.e. OC-specific runtime injections)
globals = {
    "component",
    "computer",
    "event",
    "term",
    "robot",
    "unicode",
    "filesystem",
    "serialization",
    "thread",
}

read_globals = {
    "arg",
    "bit",
    "bit32",
}

exclude_files = {
    "references/**",
    "legacy/**",
    "graphify-out/**",
    ".claude/**",
    "subnet_broker/network_protocols.lua",
    "orchestrator/network_protocols.lua",
}

ignore = {
    611,  -- Trailing whitespace
    614,  -- Line too long
    143,  -- Accessing undefined field of global
    113,  -- Accessing undefined variable
    122,  -- Setting read-only global
    111,
    131,  -- Mutating/setting non-standard global
    211,
    212,
    213,  -- Unused argument/variable/loop variable
    311,  -- Value assigned but never accessed
    411,
    421,
    423,  -- Shadowing/redefining local
    511,  -- Loop executed at most once
}