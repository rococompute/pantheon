#!/bin/sh
# Fixed Soma connection-offer counts and admission. No running node and no sockets.
set -eu
cd "$(dirname "$0")/.."
conn_offer_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-conn-offer.XXXXXX")
trap 'rm -rf "$conn_offer_test_dir"' EXIT HUP INT TERM
if ! soma run test/conn_offer.soma > "$conn_offer_test_dir/out" 2> "$conn_offer_test_dir/err"; then
  cat "$conn_offer_test_dir/err" "$conn_offer_test_dir/out"
  exit 1
fi
cat "$conn_offer_test_dir/out"
if grep -q '^FAIL ' "$conn_offer_test_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$conn_offer_test_dir/out")" -eq 8 ]
echo 'PASS Soma connection-offer counts'
