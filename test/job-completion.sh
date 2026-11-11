#!/bin/sh
# Fixed Soma results; process integration remains covered by e2e's model/CI cases.
set -eu
cd "$(dirname "$0")/.."
job_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-job-result.XXXXXX")
trap 'rm -rf "$job_test_dir"' EXIT HUP INT TERM
if ! soma run test/job_completion.soma > "$job_test_dir/out" 2> "$job_test_dir/err"; then
  cat "$job_test_dir/err" "$job_test_dir/out"
  exit 1
fi
cat "$job_test_dir/out"
if grep -q '^FAIL ' "$job_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$job_test_dir/out")" -eq 21 ]
echo 'PASS Soma job completion and byte framing'
