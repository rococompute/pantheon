#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
soma run test/certified_roster.soma > "$T/actual"
cat > "$T/expected" <<'EXPECTED'
ok exact certified window
ok missing head refused
ok missing intermediate record refused
ok wrong certificate height refused
ok missing actual block refused
ok wrong actual block refused
ok bad signature refused
ok insufficient quorum refused
ok no height zero certificate
ok zero window is empty
ok certified leave admitted
ok gap cannot authorize leave
ok latest heartbeat resets absence
ok two observations cannot meet three-block threshold
ok certified seven-to-six activation
ok certified seven-to-six quorums
ok certified four-to-three quorums
ok certified delayed rejoin
ok minimum roster enforced
ok zero delay still later
ok previous roster chosen by certificate height
ok removed signer refused at later height
ok pending removals share minimum
ok nonleader cannot remove
ok another member cannot request rejoin
ok nongenesismember cannot join
EXPECTED
diff -u "$T/expected" "$T/actual"
echo 'PASS certified roster (26 exact checks)'
