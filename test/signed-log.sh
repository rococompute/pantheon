#!/bin/sh
# signed.log lines read at startup, in Soma, with no node and no disk.
set -eu
cd "$(dirname "$0")/.."
signed_log_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-signed-log.XXXXXX")
trap 'rm -rf "$signed_log_dir"' EXIT HUP INT TERM
if ! soma run test/signed_log.soma > "$signed_log_dir/out" 2> "$signed_log_dir/err"; then
  cat "$signed_log_dir/err" "$signed_log_dir/out"
  exit 1
fi
cat "$signed_log_dir/out"
if grep -q '^FAIL ' "$signed_log_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$signed_log_dir/out")" -eq 12 ]
echo 'PASS signed log'
