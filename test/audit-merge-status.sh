#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
status_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-status.XXXXXX")
trap 'rm -rf "$status_test_dir"' EXIT HUP INT TERM
if ! soma run test/audit_merge_status.soma > "$status_test_dir/out" 2> "$status_test_dir/err"; then
  cat "$status_test_dir/err" "$status_test_dir/out"
  exit 1
fi
cat "$status_test_dir/out"
if grep -q '^FAIL ' "$status_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$status_test_dir/out")" -eq 23 ]
echo 'PASS signed attestation reasons, settlement diagnostics and market JSON'
