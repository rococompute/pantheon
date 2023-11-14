#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
soma run test/roster_admission.soma > "$T/actual"
cat > "$T/expected" <<'EXPECTED'
ok leave at threshold
ok threshold minus one waits
ok latest heartbeat resets
ok no history cannot remove
ok zero absence threshold disabled
ok only leader removes
ok outsider cannot remove even as leader
ok minimum roster enforced
ok minimum zero still keeps one
ok pending removals share minimum
ok duplicate pending removal refused
ok earlier activation refused
ok cannot remove already removed member
ok cannot join while still active
ok cannot join before pending removal
ok non-genesis join refused
ok cannot join on another member's behalf
ok removed member joins itself
ok duplicate pending join refused
ok exact leave arity
ok exact join arity
ok unknown operation refused
ok seven unchanged at commit
ok seven until effective height
ok six at effective height
ok seven to six thresholds
ok four to three thresholds
ok zero delay takes next height
ok rejoin waits for effective height
ok rejoin restores four
ok rejoin thresholds
ok admitted schedule appends exactly once
EXPECTED
diff -u "$T/expected" "$T/actual"
echo 'PASS roster admission (32 exact checks)'
