#!/bin/sh
# A peer line's members read in Soma from real yojson tokens, without a node.
set -eu
cd "$(dirname "$0")/.."
peer_members_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-peer-members.XXXXXX")
trap 'rm -rf "$peer_members_dir"' EXIT HUP INT TERM
if ! soma run test/peer_members.soma > "$peer_members_dir/out" 2> "$peer_members_dir/err"; then
  cat "$peer_members_dir/err" "$peer_members_dir/out"
  exit 1
fi
cat "$peer_members_dir/out"
if grep -q '^FAIL ' "$peer_members_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$peer_members_dir/out")" -eq 13 ]
echo 'PASS peer members'
