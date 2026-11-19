#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
mkdir "$t/home"
"${SOMA:-soma}" run test/audit_leader_archive.soma -- "$t/home" > "$t/out" 2> "$t/log" || { cat "$t/log" "$t/out"; exit 1; }
cat "$t/out"
if grep -q '^FAIL ' "$t/out"; then exit 1; fi
test "$(grep -c '^ok ' "$t/out")" -eq 5
