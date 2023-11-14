#!/bin/sh
# Fixed Soma held-request events. No running node and no sockets.
set -eu
cd "$(dirname "$0")/.."
held_events_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-held-events.XXXXXX")
trap 'rm -rf "$held_events_test_dir"' EXIT HUP INT TERM
if ! soma run test/held_events.soma > "$held_events_test_dir/out" 2> "$held_events_test_dir/err"; then
  cat "$held_events_test_dir/err" "$held_events_test_dir/out"
  exit 1
fi
cat "$held_events_test_dir/out"
if grep -q '^FAIL ' "$held_events_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$held_events_test_dir/out")" -eq 5 ]
echo 'PASS Soma held-request events'
