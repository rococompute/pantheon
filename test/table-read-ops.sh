#!/bin/sh
# U-1: peer links and job control as node operations (test/table_read_ops.soma).
set -eu
cd "$(dirname "$0")/.."
link_job_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-link-job.XXXXXX")
trap 'rm -rf "$link_job_dir"' EXIT HUP INT TERM
if ! timeout 300 soma run test/table_read_ops.soma > "$link_job_dir/out" 2> "$link_job_dir/log"; then
  cat "$link_job_dir/log" "$link_job_dir/out"
  exit 1
fi
cat "$link_job_dir/out"
if grep -q '^FAIL ' "$link_job_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$link_job_dir/out")" -eq 5 ]
echo 'PASS table read operations'
