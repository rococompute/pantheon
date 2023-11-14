#!/bin/sh
# The llm case's Soma functions on fixed inputs (replace_all, plan_open, the
# call gate and log lines, listing and file budgets, and the prompts of the
# draft, pick, patch and attest requests), with no running node.
set -eu
cd "$(dirname "$0")/.."
llm_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-llm-soma.XXXXXX")
trap 'rm -rf "$llm_test_dir"' EXIT HUP INT TERM
if ! soma run test/llm_soma_prompt.soma > "$llm_test_dir/out" 2> "$llm_test_dir/err"; then
  cat "$llm_test_dir/err" "$llm_test_dir/out"
  exit 1
fi
cat "$llm_test_dir/out"
if grep -q '^FAIL ' "$llm_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$llm_test_dir/out")" -eq 63 ]
echo 'PASS llm prompt assembly in Soma on fixed inputs'
