---
name: run-autoos
description: Build, test, and syntax-check AutoOS Lua modules for OpenComputers (GTNH). Run the test suite, parse-check source files, or drive individual tests.
---

# run-autoos

AutoOS is a decoupled manufacturing execution system for GregTech New Horizons (GTNH) OpenComputers. Lua modules deploy to in-game OC computers — desktop testing uses Python+Lupa (embeds Lua 5.5, compatible with the project's Lua 5.2+ code).

Paths below are relative to the repo root.

## Prerequisites

```
pip install lupa
```

## Run (agent path)

The driver runs Lua tests via Python+Lupa. All three modes verified working.

```bash
# Full test suite — 94 checks across 8 test files
python .claude/skills/run-autoos/driver.py

# Parse-check all source files (suppresses output, catches syntax errors)
python .claude/skills/run-autoos/driver.py --smoke

# Run one test file
python .claude/skills/run-autoos/driver.py tests/central_dispatch_test.lua
```

## Direct invocation

Import individual Lua modules into Python for isolated testing:

```python
from lupa import LuaRuntime
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('package.path = "subnet_broker/?.lua;orchestrator/?.lua;" .. package.path')

# Load and test a module directly
cfg = lua.require("config")
print(cfg.validate(cfg))  # -> true

Scheduler = lua.require("coroutine_scheduler")
# ... instantiate with mock deps and test
```

## Test (existing test suite)

```bash
python .claude/skills/run-autoos/driver.py
```

94 checks across 8 test files: coroutine scheduler, fluid tanks, descriptor cache, array watch, broker scheduler, lane coroutine, lane dispatch, central dispatch.

## Gotchas

- **`os.exit()` in test files kills Python.** The driver stubs `os.exit` to a no-op before running tests.
- **Shebang lines (`#!/usr/bin/env lua`) are not valid Lua.** The driver strips them before execution.
- **Module requires fail outside package.path.** In-game entry points (`start.lua`, `broker_main.lua`) modify `package.path` to include their home directory. Parse-check reports these as "FAIL" because they `require` sibling modules before path setup. The test files handle path setup correctly — use those as the reference pattern.
- **`component`, `filesystem`, `modem` are OpenComputers APIs** — they don't exist on desktop. Files that `require` these directly (modem_comm_test.lua, find.lua, diag.lua) are interactive in-game tools, not testable on desktop. Core library modules (`hw.lua`, `config.lua`, `coroutine_scheduler.lua`, etc.) isolate these behind dependency injection and parse fine.
- **Lua 5.5 (lupa) vs Lua 5.2 (in-game).** The project uses `goto`/labels (Lua 5.2+) and `table.unpack`. Lupa's Lua 5.5 is backward-compatible with all features used. Final verification on actual OC hardware is still needed for OC-specific APIs.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ModuleNotFoundError: No module named 'lupa'` | `pip install lupa` |
| `attempt to index a nil value (global 'component')` | Expected — file uses OC API directly. Core logic files don't do this. |
| Test output mentions missing files in `/home/orchestrator/` | Expected from `start.lua` boot helpers — they check for sibling files using in-game paths. Not an error. |
| `module 'X' not found` on parse-check | File `require`s a module before setting up `package.path`. The test files handle this correctly. |
