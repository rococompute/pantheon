#!/bin/sh
# Decisions and assertions run as extracted Soma, including native signatures.
set -eu
cd "$(dirname "$0")/.."
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
for item in audit_net_resources:10 audit_consensus_resources:12 audit_parser_resources:11; do
  name=${item%:*}
  count=${item#*:}
  "${SOMA:-soma}" run "test/$name.soma" > "$t/out" 2> "$t/log" || { cat "$t/log" "$t/out"; exit 1; }
  cat "$t/out"
  if grep -q '^FAIL ' "$t/out"; then exit 1; fi
  test "$(grep -c '^ok ' "$t/out")" -eq "$count"
done
