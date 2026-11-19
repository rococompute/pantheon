#!/bin/sh
# No processes or model calls: extracted production agent/runtime/market code.
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp)
trap 'rm -f "$out"' EXIT HUP INT TERM
"${SOMA:-soma}" run test/audit_draw_recovery.soma > "$out" 2>&1 || { cat "$out"; exit 1; }
cat "$out"
if grep -q '^FAIL ' "$out"; then exit 1; fi
test "$(grep -c '^ok ' "$out")" -eq 13
