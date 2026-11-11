#!/bin/sh
# Actual Yojson peer members through Soma's raw-line gate, without a node.
set -eu
cd "$(dirname "$0")/.."
peer_raw_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-peer-raw.XXXXXX")
trap 'rm -rf "$peer_raw_test_dir"' EXIT HUP INT TERM
if ! soma run test/peer_raw.soma > "$peer_raw_test_dir/out" 2> "$peer_raw_test_dir/err"; then
  cat "$peer_raw_test_dir/err" "$peer_raw_test_dir/out"
  exit 1
fi
cat "$peer_raw_test_dir/out"
if grep -q '^FAIL ' "$peer_raw_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$peer_raw_test_dir/out")" -eq 11 ]
echo 'PASS raw peer-line integration'
