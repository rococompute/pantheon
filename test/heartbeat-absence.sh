#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
soma run test/heartbeat_absence.soma > "$T/actual"
cat > "$T/expected" <<'EXPECTED'
2
3
0
0
kept
remove
d
reset
disabled
nonmember
EXPECTED
diff -u "$T/expected" "$T/actual"
echo 'PASS heartbeat absence'
