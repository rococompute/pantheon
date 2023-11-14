#!/bin/sh
# Pure model request decisions and prompt assembly, no live node.
set -eu
cd "$(dirname "$0")/.."
llm_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-llm-request.XXXXXX")
trap 'rm -rf "$llm_test_dir"' EXIT HUP INT TERM
soma run test/llm_request.soma > "$llm_test_dir/out"
cat "$llm_test_dir/out"
! grep -q '^FAIL ' "$llm_test_dir/out"
[ "$(grep -c '^ok ' "$llm_test_dir/out")" -eq 16 ]
