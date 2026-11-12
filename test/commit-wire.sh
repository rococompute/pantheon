#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
wire_dir=$(mktemp -d)
trap 'rm -rf "$wire_dir"' EXIT HUP INT TERM
soma run test/commit_wire.soma > "$wire_dir/out"
cat > "$wire_dir/expected" <<'EXPECTED'
true
true
true
true
true
true
true
true
EXPECTED
diff -u "$wire_dir/expected" "$wire_dir/out"
echo 'PASS commit wire'
