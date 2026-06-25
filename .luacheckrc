std = "lua52"

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
    "page",
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
    "614",  -- Trailing whitespace
    "631",  -- Line too long
    "143",  -- Accessing undefined field of global
    "113",  -- Accessing undefined variable
    "122",  -- Setting read-only global
    "111",
    "131",  -- Mutating/setting non-standard global
    "211",
    "212",
    "213",  -- Unused argument/variable/loop variable
    "311",  -- Value assigned but never accessed
    "411",
    "421",
    "423",  -- Shadowing/redefining local
    "512",  -- Loop executed at most once
    "611",  -- A line consists of nothing but whitespace

}