#!/bin/sh
# genesis.json into boot events, in Soma, through the real JSON binding.
set -eu
cd "$(dirname "$0")/.."
genesis_boot_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-genesis-boot.XXXXXX")
trap 'rm -rf "$genesis_boot_dir"' EXIT HUP INT TERM
if ! timeout 300 soma run test/genesis_boot.soma > "$genesis_boot_dir/out" 2> "$genesis_boot_dir/log"; then
  cat "$genesis_boot_dir/log" "$genesis_boot_dir/out"
  exit 1
fi
cat "$genesis_boot_dir/out"
if grep -q '^FAIL ' "$genesis_boot_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$genesis_boot_dir/out")" -eq 10 ]
echo 'PASS genesis boot events'
