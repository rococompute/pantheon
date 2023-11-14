#!/bin/sh
# The check_result event chosen in Soma, through the real plain-text binding.
set -eu
cd "$(dirname "$0")/.."
check_event_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-check-event.XXXXXX")
trap 'rm -rf "$check_event_dir"' EXIT HUP INT TERM
if ! timeout 300 soma run test/check_unchecked_reason.soma > "$check_event_dir/out" 2> "$check_event_dir/log"; then
  cat "$check_event_dir/log" "$check_event_dir/out"
  exit 1
fi
cat "$check_event_dir/out"
if grep -q '^FAIL ' "$check_event_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$check_event_dir/out")" -eq 4 ]
echo 'PASS check result event'
