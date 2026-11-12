#!/bin/sh
# What a check job's output becomes. Fixed Soma results, no node.
set -eu
cd "$(dirname "$0")/.."
dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-check-apply.XXXXXX")
trap 'rm -rf "$dir"' EXIT HUP INT TERM
if ! soma run test/check_apply.soma > "$dir/out" 2> "$dir/err"; then
  cat "$dir/err" "$dir/out"
  exit 1
fi
cat "$dir/out"
if grep -q '^FAIL ' "$dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$dir/out")" -eq 19 ]
want=$(python3 -c 'import hashlib; print(hashlib.sha256(b"liereq-9").hexdigest()[:40])')
got=$(sed -n 's/^lie //p' "$dir/out")
[ "$got" = "$want" ] || { echo "FAIL lie hash $got want $want"; exit 1; }
echo "PASS check apply ($got)"
