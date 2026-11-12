#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
served_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-served-io.XXXXXX")
trap 'rm -rf "$served_test_dir"' EXIT HUP INT TERM
if ! timeout 120 soma run test/served_io.soma > "$served_test_dir/out" 2> "$served_test_dir/err"; then
 cat "$served_test_dir/err" "$served_test_dir/out"
 exit 1
fi
cat > "$served_test_dir/expected" <<'EXPECTED'
ok read wire
ok lossless quarter wire
ok zero timestamp is present
ok missing timestamp is absent
ok marker names roundtrip
ok malformed read arity
ok malformed write arity
ok no premature retry after rounding down
ok quarter boundary equality
ok quarter just before boundary
ok quarter just after boundary
ok no late retry after rounding up
ok three quarter just before boundary
ok high precision epoch timestamp
ok production codec finite range
ok negative zero retained
ok display formatting preserved
ok missing read writes before block reads
ok present read suppresses all effects
ok exact fractional boundary issues write
ok failed write prevents block reads
ok silent still remembers timestamp
ok absent peer still remembers timestamp
ok empty range still remembers timestamp
ok missing script reply refuses
ok unexpected reply refuses
ok height and peer are independent wire keys
ok remember action uses production codec
EXPECTED
diff -u "$served_test_dir/expected" "$served_test_dir/out"
echo 'PASS served I/O (28 exact checks with production float codec)'
