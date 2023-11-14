#!/bin/sh
# Fixed request queues and probe flags, no running node or timing races.
set -eu
cd "$(dirname "$0")/.."
held_release_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-held-release.XXXXXX")
trap 'rm -rf "$held_release_dir"' EXIT HUP INT TERM
if ! timeout 120 soma run test/held_release.soma > "$held_release_dir/out" 2> "$held_release_dir/err"; then
  cat "$held_release_dir/err" "$held_release_dir/out"
  exit 1
fi
cat "$held_release_dir/out"
! grep -q '^FAIL ' "$held_release_dir/out"
[ "$(grep -c '^ok ' "$held_release_dir/out")" -eq 26 ]
echo 'PASS held request batches and probe metadata'
