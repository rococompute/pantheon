#!/bin/sh
# Fixed Soma results and baseline role prompt bytes, with no running node.
set -eu
cd "$(dirname "$0")/.."
prompt_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-prompt.XXXXXX")
trap 'rm -rf "$prompt_test_dir"' EXIT HUP INT TERM
if ! soma run test/prompt_assembly.soma > "$prompt_test_dir/out" 2> "$prompt_test_dir/err"; then
  cat "$prompt_test_dir/err" "$prompt_test_dir/out"
  exit 1
fi
cat "$prompt_test_dir/out"
if grep -q '^FAIL ' "$prompt_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$prompt_test_dir/out")" -eq 20 ]
echo 'PASS pure Soma prompt assembly and role prompt bytes'
