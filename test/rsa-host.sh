#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
rsa_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-rsa.XXXXXX")
trap 'rm -rf "$rsa_dir"' EXIT HUP INT TERM
soma run test/rsa_host.soma > "$rsa_dir/out"
cat "$rsa_dir/out"
! grep -q '^FAIL ' "$rsa_dir/out"
[ "$(grep -c '^ok ' "$rsa_dir/out")" -eq 7 ]
echo 'PASS RSA host integration'
