#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
soma run test/commit_evidence.soma > "$T/actual"
cat > "$T/expected" <<'EXPECTED'
ok genuine callback evidence
ok canonical previous-roster order
ok arrival order does not affect names
ok too few distinct signers
ok duplicate cannot pad quorum
ok duplicate even with a quorum refused
ok oversized certificate refused
ok outsider with a valid token refused
ok bad signature refused
ok cross-chain signature refused
ok no signature verification means no evidence
ok wrong previous block refused
ok wrong height refused
ok wrong round refused
ok nil vote refused
ok prevote is not a precommit
ok vote payload refused
ok invalid valid-round refused
ok malformed number refused
ok exact signed numeric spelling retained
ok empty previous roster refused
ok height zero has no certificate
ok seven-before-six uses previous roster
ok current six roster cannot reinterpret old certificate
ok four-before-three uses previous roster
ok current three roster cannot reinterpret old certificate
ok first heartbeat records height and value
ok second heartbeat preserves prefix
ok missing intermediate heartbeat refused
ok repeated heartbeat refused
ok empty history cannot start at height two
ok invalid certificate cannot advance history
EXPECTED
diff -u "$T/expected" "$T/actual"
echo 'PASS commit evidence (32 exact checks)'
