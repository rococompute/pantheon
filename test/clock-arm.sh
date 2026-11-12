#!/bin/sh
# Job deadlines, timer order and the select wait. Fixed Soma results, no node.
set -eu
cd "$(dirname "$0")/.."
clock_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-clock-arm.XXXXXX")
trap 'rm -rf "$clock_test_dir"' EXIT HUP INT TERM
if ! soma run test/clock_arm.soma > "$clock_test_dir/out" 2> "$clock_test_dir/err"; then
  cat "$clock_test_dir/err" "$clock_test_dir/out"
  exit 1
fi
cat "$clock_test_dir/out"
if grep -q '^FAIL ' "$clock_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$clock_test_dir/out")" -eq 16 ]
echo 'PASS Soma deadlines and timer order'
