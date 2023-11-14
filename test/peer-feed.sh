#!/bin/sh
# Fixed Soma peer-framing results. No running node and no timers.
set -eu
cd "$(dirname "$0")/.."
peer_feed_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-peer-feed.XXXXXX")
trap 'rm -rf "$peer_feed_test_dir"' EXIT HUP INT TERM
if ! soma run test/peer_feed.soma > "$peer_feed_test_dir/out" 2> "$peer_feed_test_dir/err"; then
  cat "$peer_feed_test_dir/err" "$peer_feed_test_dir/out"
  exit 1
fi
cat "$peer_feed_test_dir/out"
if grep -q '^FAIL ' "$peer_feed_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$peer_feed_test_dir/out")" -eq 10 ]
echo 'PASS Soma peer framing and cap'
