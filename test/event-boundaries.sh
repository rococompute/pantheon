#!/bin/sh
# Fixed Soma framing, admission and event classification. No running node and no sockets.
set -eu
cd "$(dirname "$0")/.."
event_boundaries_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-event-boundaries.XXXXXX")
trap 'rm -rf "$event_boundaries_test_dir"' EXIT HUP INT TERM
if ! soma run test/event_boundaries.soma > "$event_boundaries_test_dir/out" 2> "$event_boundaries_test_dir/err"; then
  cat "$event_boundaries_test_dir/err" "$event_boundaries_test_dir/out"
  exit 1
fi
cat "$event_boundaries_test_dir/out"
if grep -q '^FAIL ' "$event_boundaries_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$event_boundaries_test_dir/out")" -eq 20 ]
echo 'PASS Soma event boundaries'
