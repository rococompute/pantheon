#!/bin/sh
# Fixed Soma job-buffer results. No running node and no timers.
set -eu
cd "$(dirname "$0")/.."
job_feed_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-job-feed.XXXXXX")
trap 'rm -rf "$job_feed_test_dir"' EXIT HUP INT TERM
if ! soma run test/job_feed.soma > "$job_feed_test_dir/out" 2> "$job_feed_test_dir/err"; then
  cat "$job_feed_test_dir/err" "$job_feed_test_dir/out"
  exit 1
fi
cat "$job_feed_test_dir/out"
if grep -q '^FAIL ' "$job_feed_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$job_feed_test_dir/out")" -eq 14 ]
echo 'PASS Soma job output cap'
