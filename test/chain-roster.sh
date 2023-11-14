#!/bin/sh
# Deterministic framed committed-chain evidence through production admission.
set -eu
cd "$(dirname "$0")/.."
chain_test_dir=$(mktemp -d)
trap 'rm -rf "$chain_test_dir"' EXIT HUP INT TERM
if ! timeout 300 soma run test/chain_roster.soma > "$chain_test_dir/out" 2> "$chain_test_dir/log"; then
  cat "$chain_test_dir/log" "$chain_test_dir/out"
  exit 1
fi
cat "$chain_test_dir/out"
! grep -q '^FAIL ' "$chain_test_dir/out"
[ "$(grep -c '^ok ' "$chain_test_dir/out")" -eq 38 ]
echo 'PASS bounded prior-chain roster admission'
