#!/bin/sh
# A --goal file becomes agent goal events in Soma. Fixed texts, no node.
set -eu
cd "$(dirname "$0")/.."
dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-goal-lines.XXXXXX")
trap 'rm -rf "$dir"' EXIT HUP INT TERM
if ! soma run test/goal_lines.soma > "$dir/out" 2> "$dir/err"; then
  cat "$dir/err" "$dir/out"
  exit 1
fi
cat "$dir/out"
if grep -q '^FAIL ' "$dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$dir/out")" -eq 10 ]
echo 'PASS goal lines'
