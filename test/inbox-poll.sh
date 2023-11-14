#!/bin/sh
# Fixed-input inbox acquisition and typed effect order; no running node.
set -eu
cd "$(dirname "$0")/.."
inbox_poll_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-inbox-poll.XXXXXX")
trap 'rm -rf "$inbox_poll_dir"' EXIT HUP INT TERM
if ! timeout 120 soma run test/inbox_poll.soma > "$inbox_poll_dir/out" 2> "$inbox_poll_dir/err"; then
  cat "$inbox_poll_dir/err" "$inbox_poll_dir/out"
  exit 1
fi
cat "$inbox_poll_dir/out"
! grep -q '^FAIL ' "$inbox_poll_dir/out"
[ "$(grep -c '^ok ' "$inbox_poll_dir/out")" -eq 30 ]
echo 'PASS Soma inbox polling and queue-before-remove'
