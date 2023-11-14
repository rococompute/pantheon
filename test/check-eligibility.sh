#!/bin/sh
# Check launch eligibility and queued refusal facts, directly in Soma.
set -eu
cd "$(dirname "$0")/.."
check_event_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-check-event.XXXXXX")
trap 'rm -rf "$check_event_dir"' EXIT HUP INT TERM
if ! timeout 300 soma run test/check_eligibility.soma > "$check_event_dir/out" 2> "$check_event_dir/log"; then
  cat "$check_event_dir/log" "$check_event_dir/out"
  exit 1
fi
cat "$check_event_dir/out"
if grep -q '^FAIL ' "$check_event_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$check_event_dir/out")" -eq 6 ]
echo 'PASS check eligibility'
