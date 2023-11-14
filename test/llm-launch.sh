#!/bin/sh
# Pure model-launch decisions (cmd: tool checkout, grok request), no live node.
set -eu
cd "$(dirname "$0")/.."
llm_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-llm-launch.XXXXXX")
trap 'rm -rf "$llm_test_dir"' EXIT HUP INT TERM
soma run test/llm_launch.soma > "$llm_test_dir/out"
cat "$llm_test_dir/out"
! grep -q '^FAIL ' "$llm_test_dir/out"
[ "$(grep -c '^ok ' "$llm_test_dir/out")" -eq 14 ]
