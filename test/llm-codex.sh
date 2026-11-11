#!/bin/sh
# Codex output selection in Soma, without a running node.
set -eu
cd "$(dirname "$0")/.."
llm_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-llm-codex.XXXXXX")
trap 'rm -rf "$llm_test_dir"' EXIT HUP INT TERM
soma run test/llm_codex.soma > "$llm_test_dir/out"
cat "$llm_test_dir/out"
! grep -q '^FAIL ' "$llm_test_dir/out"
[ "$(grep -c '^ok ' "$llm_test_dir/out")" -eq 8 ]
