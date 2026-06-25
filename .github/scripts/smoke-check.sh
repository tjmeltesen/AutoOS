#!/usr/bin/env bash
# AutoOS Lua parse-check via luac5.2
# Usage: smoke-check.sh [dir...]
# Exits 0 if all parse, 1 if any fail.

set -euo pipefail

DIRS=("${@:-subnet_broker orchestrator shared}")

echo ""
echo "=== Parse Check (luac5.2 -p) ==="

PASSED=0
FAILED=0

for d in "${DIRS[@]}"; do
    if [ ! -d "$d" ]; then
        echo "SKIP: directory $d not found"
        continue
    fi
    while IFS= read -r -d '' f; do
        rel="${f#./}"
        if luac5.2 -p "$f" 2>/dev/null; then
            echo "  OK  $rel"
            PASSED=$((PASSED + 1))
        else
            echo "  FAIL $rel"
            FAILED=$((FAILED + 1))
        fi
    done < <(find "$d" -name '*.lua' -print0)
done

echo ""
echo "=== Parse: ${PASSED} passed, ${FAILED} failed ==="
if [ $FAILED -gt 0 ]; then
    exit 1
fi
exit 0
