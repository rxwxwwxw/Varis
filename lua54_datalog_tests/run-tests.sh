#!/bin/sh
# Usage: ./run-tests.sh /path/to/extended-lua
# The binary must accept one Lua source filename as its argument.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=${1:-${LUA_BIN:-lua}}
TIMEOUT=${TEST_TIMEOUT:-300}
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT HUP INT TERM
passes=0
failures=0

run_test() {
    python3 -c '
import subprocess, sys
timeout_sec = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    res = subprocess.run(cmd, timeout=timeout_sec)
    if res.returncode < 0:
        sys.stderr.write("Test process crashed with signal " + str(-res.returncode) + "\n")
        sys.exit(125)
    sys.exit(res.returncode)
except subprocess.TimeoutExpired:
    sys.stderr.write("Test timed out after " + str(timeout_sec) + "s\n")
    sys.exit(124)
' "$TIMEOUT" "$@"
}

for file in "$ROOT"/positive/*.lua; do
    name=$(basename "$file")
    if run_test "$BIN" "$file" >"$LOG" 2>&1; then
        printf '[PASS] %s\n' "$name"
        passes=$((passes + 1))
    else
        printf '[FAIL] %s (expected successful execution)\n' "$name"
        cat "$LOG"
        failures=$((failures + 1))
    fi
done

for file in "$ROOT"/negative/*.lua; do
    name=$(basename "$file")
    case "$name" in
        13_unsafe_negation.lua) expected="variable '\?x' in rule head is not bound" ;;
        14_negation_cycle.lua) expected='negation cycle' ;;
        15_relation_arity_mismatch.lua) expected="relation 'edge' expects arity 2, got 1" ;;
        *) printf '[FAIL] %s (missing expected diagnostic)\n' "$name"; failures=$((failures + 1)); continue ;;
    esac
    if run_test "$BIN" "$file" >"$LOG" 2>&1; then
        printf '[FAIL] %s (expected validation error)\n' "$name"
        failures=$((failures + 1))
    elif grep -Eq 'Test timed out|Test process crashed' "$LOG"; then
        printf '[FAIL] %s (test timed out or crashed)\n' "$name"
        cat "$LOG"
        failures=$((failures + 1))
    elif grep -q 'UNEXPECTED SUCCESS' "$LOG"; then
        printf '[FAIL] %s (reached fallback error, not a validation failure)\n' "$name"
        cat "$LOG"
        failures=$((failures + 1))
    elif ! grep -Eq "$expected" "$LOG"; then
        printf '[FAIL] %s (wrong rejection diagnostic)\n' "$name"
        cat "$LOG"
        failures=$((failures + 1))
    else
        printf '[PASS] %s (expected rejection)\n' "$name"
        passes=$((passes + 1))
    fi
done

printf '\nResult: %d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
