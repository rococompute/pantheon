#!/bin/sh
# M-3 part: the market follows the roster at its height, through settle,
# maybe_draw and maybe_end_term on fixed inputs (test/roster_activation.soma).
set -eu
cd "$(dirname "$0")/.."
roster_activation_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-roster-activation.XXXXXX")
trap 'rm -rf "$roster_activation_dir"' EXIT HUP INT TERM
if ! timeout 300 soma run test/roster_activation.soma > "$roster_activation_dir/out" 2> "$roster_activation_dir/log"; then
  cat "$roster_activation_dir/log" "$roster_activation_dir/out"
  exit 1
fi
cat "$roster_activation_dir/out"
if grep -q '^FAIL ' "$roster_activation_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$roster_activation_dir/out")" -eq 17 ]
echo 'PASS roster activation'
