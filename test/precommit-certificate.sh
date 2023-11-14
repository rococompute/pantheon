#!/bin/bash
# Certificate extraction: duplicates and unrelated votes never add names.
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
soma run test/precommit_certificate.soma > "$T/actual"
cat > "$T/expected" <<'EXPECTED'
b
a
d
--
c
--
c
--
--
3
3
EXPECTED
diff -u "$T/expected" "$T/actual"
echo 'PASS precommit certificate'
