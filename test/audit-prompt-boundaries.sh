#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
prompt_boundary_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-prompt-boundaries.XXXXXX")
trap 'rm -rf "$prompt_boundary_dir"' EXIT HUP INT TERM
if ! soma run test/audit_prompt_boundaries.soma > "$prompt_boundary_dir/out" 2> "$prompt_boundary_dir/err"; then
  cat "$prompt_boundary_dir/err" "$prompt_boundary_dir/out"
  exit 1
fi
cat "$prompt_boundary_dir/out"
if grep -q '^FAIL ' "$prompt_boundary_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$prompt_boundary_dir/out")" -eq 16 ]
echo 'PASS prompt substitution, names, hold bounds and generated image source'
