#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
resend_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-resend-io.XXXXXX")
trap 'rm -rf "$resend_test_dir"' EXIT HUP INT TERM
if ! timeout 120 soma run test/resend_io.soma > "$resend_test_dir/out" 2> "$resend_test_dir/err"; then
  cat "$resend_test_dir/err" "$resend_test_dir/out"
  exit 1
fi
cat "$resend_test_dir/out"
! grep -q '^FAIL ' "$resend_test_dir/out"
[ "$(grep -c '^ok ' "$resend_test_dir/out")" -eq 23 ]
echo 'PASS typed resend operation and scripted broadcast effects'
