#!/bin/sh
# Replay of blocks.log lines, with no node and no disk.
set -eu
cd "$(dirname "$0")/.."
block_log_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-block-log.XXXXXX")
trap 'rm -rf "$block_log_dir"' EXIT
if ! soma run test/block_log.soma > "$block_log_dir/out" 2> "$block_log_dir/err"; then
  cat "$block_log_dir/err" "$block_log_dir/out"
  exit 1
fi
cat "$block_log_dir/out"
if grep -q '^FAIL ' "$block_log_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$block_log_dir/out")" -eq 8 ]
echo 'PASS block log'
