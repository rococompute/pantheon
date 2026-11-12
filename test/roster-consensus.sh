#!/bin/sh
# M-3 part: consensus switches its validators at the height a roster change
# takes effect, on fixed inputs (test/roster_consensus.soma).
set -eu
cd "$(dirname "$0")/.."
roster_consensus_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-roster-consensus.XXXXXX")
trap 'rm -rf "$roster_consensus_dir"' EXIT HUP INT TERM
if ! timeout 300 soma run test/roster_consensus.soma > "$roster_consensus_dir/out" 2> "$roster_consensus_dir/log"; then
  cat "$roster_consensus_dir/log" "$roster_consensus_dir/out"
  exit 1
fi
cat "$roster_consensus_dir/out"
if grep -q '^FAIL ' "$roster_consensus_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$roster_consensus_dir/out")" -eq 10 ]
echo 'PASS roster consensus'
