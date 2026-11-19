#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp)
trap 'rm -f "$out"' EXIT HUP INT TERM
"${SOMA:-soma}" run test/audit_service_cleanup.soma > "$out" 2>&1 || { cat "$out"; exit 1; }
cat "$out"
! grep -q '^FAIL ' "$out"
test "$(grep -c '^ok ' "$out")" -eq 39
