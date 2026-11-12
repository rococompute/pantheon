#!/bin/sh
# Grok's reply content (choices.0.message.content) decided in Soma, on fixed tokens.
set -eu
cd "$(dirname "$0")/.."
llm_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-llm-grok.XXXXXX")
trap 'rm -rf "$llm_test_dir"' EXIT HUP INT TERM
soma run test/llm_grok.soma > "$llm_test_dir/out"
cat "$llm_test_dir/out"
! grep -q '^FAIL ' "$llm_test_dir/out"
[ "$(grep -c '^ok ' "$llm_test_dir/out")" -eq 17 ]
