#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp); script=$(mktemp)
trap 'rm -f "$out" "$script"' EXIT HUP INT TERM
"${SOMA:-soma}" run test/audit_service_jobs.soma > "$out" 2>&1 || { cat "$out"; exit 1; }
cat "$out"
! grep -q '^FAIL ' "$out"
test "$(grep -c '^ok ' "$out")" -eq 10
sed -n '/^--PAYLOAD--$/,/^--END-PAYLOAD--$/p' "$out" | sed '1d;$d' > "$script"
if sh "$script"; then echo 'FAIL bid exit 3 passed'; exit 1; else status=$?; fi
[ "$status" -eq 86 ] || { echo "FAIL payload exit 3 became $status instead of 86"; exit 1; }
# An infrastructure runner exits outside the payload wrapper.
if sh -c 'exit 3' runner 256m /tree "$(cat "$script")"; then exit 1; else status=$?; fi
[ "$status" -eq 3 ]
echo 'ok payload failure is wrapped while runner failure stays infrastructure'
