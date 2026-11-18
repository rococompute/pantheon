#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
timeout 300 soma run test/leader_chain.soma > "$t/out" 2> "$t/log" || { cat "$t/log" "$t/out"; exit 1; }
cat "$t/out"
! grep -q '^FAIL ' "$t/out"
[ "$(grep -c '^ok ' "$t/out")" -eq 13 ]
echo 'PASS leader journal semantics'
