#!/usr/bin/env bash
# AutoOS native Lua test runner
# Usage: run-tests.sh <label> <test_file...>
# Exits 0 if all pass, 1 if any fail.

set -euo pipefail

LABEL="$1"
shift

if [ $# -eq 0 ]; then
    echo "Usage: run-tests.sh <label> <test_file...>"
    exit 1
fi

echo ""
echo "=== ${LABEL} ==="

PASSED=0
FAILED=0
MISSING=0

for f in "$@"; do
    if [ ! -f "$f" ]; then
        echo "MISSING: $f"
        MISSING=$((MISSING + 1))
        continue
    fi

    echo ""
    echo "--- $f ---"

    if lua5.2 "$f"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "  FAIL: exit code $? for $f"
    fi
done

echo ""
echo "=== ${LABEL}: ${PASSED} passed, ${FAILED} failed, ${MISSING} missing ==="
if [ $FAILED -gt 0 ] || [ $MISSING -gt 0 ]; then
    exit 1
fi
exit 0
