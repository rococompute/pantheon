#!/bin/sh
# A peer line's members read in Soma from real yojson tokens, without a node.
set -eu
cd "$(dirname "$0")/.."
tx_members_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-tx-members.XXXXXX")
trap 'rm -rf "$tx_members_dir"' EXIT HUP INT TERM
if ! soma run test/tx_members.soma > "$tx_members_dir/out" 2> "$tx_members_dir/err"; then
  cat "$tx_members_dir/err" "$tx_members_dir/out"
  exit 1
fi
cat "$tx_members_dir/out"
if grep -q '^FAIL ' "$tx_members_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$tx_members_dir/out")" -eq 8 ]
echo 'PASS transaction members'
