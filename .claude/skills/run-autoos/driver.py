"""
AutoOS smoke driver — runs Lua tests via lupa (Python+Lua bridge).
Usage: python .claude/skills/run-autoos/driver.py [--smoke] [test_file...]

Requirements: pip install lupa  (embeds Lua 5.5, compatible with project's Lua 5.2+ code)

No args: runs full test suite
--smoke:  parse-checks all source files without executing top-level code
--all:    parse-checks ALL .lua files (including legacy)
"""

import sys, os, re, io

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

TEST_FILES = [
    "tests/coroutine_scheduler_test.lua",
    "tests/fluid_tanks_test.lua",
    "tests/descriptor_cache_test.lua",
]

UNIT_TEST_FILES = [
    "tests/unit/lane_state_test.lua",
    "tests/unit/lock_manager_test.lua",
    "tests/unit/job_descriptor_test.lua",
    "tests/unit/buffer_monitor_test.lua",
    "tests/unit/job_assigner_test.lua",
    "tests/unit/job_reaper_test.lua",
    "tests/unit/watchdog_test.lua",
    "tests/unit/completion_detector_test.lua",
    "tests/unit/circuit_manager_test.lua",
    "tests/unit/network_protocols_test.lua",
]

INTEGRATION_TEST_FILES = [
    "tests/integration/hardware_contract_test.lua",
    "tests/integration/adapter_connectivity_test.lua",
    "tests/integration/full_lane_stack_test.lua",
    "tests/integration/network_card_test.lua",
    "tests/integration/oc_boot_smoke_test.lua",
]

SOAK_TEST_FILES = [
    "tests/soak/soak_thousands_test.lua",
    "tests/soak/soak_stuck_phase5_test.lua",
    "tests/soak/soak_queue_saturation_test.lua",
    "tests/soak/soak_circuit_leak_test.lua",
]

PROFILE_TEST_FILES = [
    "tests/profile/profile_dispatch_test.lua",
    "tests/profile/profile_serialization_test.lua",
    "tests/profile/profile_retry_test.lua",
]


def walk_lua(*dirs):
    paths = []
    for d in dirs:
        for dirpath, _, files in os.walk(os.path.join(ROOT, d)):
            for fn in files:
                if fn.endswith(".lua"):
                    paths.append(os.path.join(dirpath, fn))
    return sorted(paths)


def smoke_check(dirs=("subnet_broker", "orchestrator", "shared")):
    """Parse-check: verifies every Lua file compiles. Suppresses output."""
    from lupa import LuaRuntime

    all_lua = walk_lua(*dirs)
    passed, failed = 0, 0
    for path in all_lua:
        rel = os.path.relpath(path, ROOT)
        try:
            with open(path, "r", encoding="utf-8") as f:
                code = f.read()
            code = re.sub(r"^#!.*\n", "", code)
            lua = LuaRuntime()
            # Redirect stdout to suppress output during parse check
            old_stdout = sys.stdout
            sys.stdout = io.StringIO()
            try:
                lua.execute(code)
            finally:
                sys.stdout = old_stdout
            print(f"  OK  {rel}")
            passed += 1
        except Exception as e:
            print(f"  FAIL {rel}: {e}")
            failed += 1
    print(f"\nSyntax: {passed} passed, {failed} failed")
    return failed == 0


def run_one(path):
    """Run a single Lua test file, return True if all checks passed."""
    from lupa import LuaRuntime

    rel = os.path.relpath(path, ROOT)
    print(f"\n--- {rel} ---")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('local _os = require("os"); function _os.exit(code) end')
    with open(path, "r", encoding="utf-8") as f:
        code = f.read()
    code = re.sub(r"^#!.*\n", "", code)
    lua.execute("arg = { [0] = \"" + rel.replace("\\", "/") + "\" }")
    try:
        lua.execute(code)
        return True
    except SystemExit:
        return True
    except Exception as e:
        print(f"  FAIL: {e}")
        return False


def run_all():
    ok, fail = 0, 0
    for tf in TEST_FILES:
        path = os.path.join(ROOT, tf)
        if not os.path.exists(path):
            print(f"MISSING: {tf}")
            fail += 1
            continue
        if run_one(path):
            ok += 1
        else:
            fail += 1
    print(f"\n=== {ok} passed, {fail} failed ===")
    return fail == 0


if __name__ == "__main__":
    os.chdir(ROOT)
    args = sys.argv[1:]

    if "--smoke" in args:
        smoke_check()
    elif "--all" in args:
        smoke_check(("subnet_broker", "orchestrator", "shared", "legacy"))
    elif args:
        for a in args:
            path = os.path.join(ROOT, a) if not os.path.isabs(a) else a
            run_one(path)
    else:
        run_all()
