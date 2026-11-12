#!/bin/sh
# blocks.log and signed.log bytes split into lines in Soma, with no node.
set -eu
cd "$(dirname "$0")/.."
log_lines_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-log-lines.XXXXXX")
trap 'rm -rf "$log_lines_dir"' EXIT
if ! soma run test/log_lines.soma > "$log_lines_dir/out" 2> "$log_lines_dir/err"; then
  cat "$log_lines_dir/err" "$log_lines_dir/out"
  exit 1
fi
cat "$log_lines_dir/out"
if grep -q '^FAIL ' "$log_lines_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$log_lines_dir/out")" -eq 10 ]
echo 'PASS log lines'
