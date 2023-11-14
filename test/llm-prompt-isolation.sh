#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out=$(soma run test/llm_prompt_isolation.soma)
printf '%s\n' "$out"
! printf '%s\n' "$out" | grep -q '^FAIL '
[ "$(printf '%s\n' "$out" | grep -c '^ok ')" -eq 6 ]
echo 'PASS prompt callback independence and replacement ordering'
