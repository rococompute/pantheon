#!/bin/sh
# Step 5: peer reads into events, the line byte cap and connection
# admission, through the Soma functions on fixed inputs. No running node.
set -eu
cd "$(dirname "$0")/.."
peer_read_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-peer-read.XXXXXX")
trap 'rm -rf "$peer_read_test_dir"' EXIT HUP INT TERM
if ! soma run test/peer_read.soma > "$peer_read_test_dir/out" 2> "$peer_read_test_dir/err"; then
  cat "$peer_read_test_dir/err" "$peer_read_test_dir/out"
  exit 1
fi
cat "$peer_read_test_dir/out"
if grep -q '^FAIL ' "$peer_read_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$peer_read_test_dir/out")" -eq 30 ]
echo 'PASS Soma peer reads, line cap and admission'
