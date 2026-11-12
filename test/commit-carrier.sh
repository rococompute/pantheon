#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
carrier_dir=$(mktemp -d)
trap 'rm -rf "$carrier_dir"' EXIT HUP INT TERM
soma run test/commit_carrier.soma > "$carrier_dir/out"
cat > "$carrier_dir/expected" <<'EXPECTED'
true
true
true
true
true
true
true
true
true
true
true
true
true
true
EXPECTED
diff -u "$carrier_dir/expected" "$carrier_dir/out"
echo 'PASS commit carrier'
