#!/bin/sh
# Discovery and failure propagation against a candidate checkout, with no
# Soma build required. Invoke explicitly: sh test/soma-misc-runner.sh.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
mkdir -p "$t/candidate tree/test-suite/misc" "$t/candidate tree/bin"
cd "$t/candidate tree"
printf '#!/bin/sh\necho candidate\n' > bin/soma
chmod +x bin/soma
export BIN="$PWD/bin" SOMA_CACHE="$t/caller-cache"
run() { sh "$here/scripts/soma-misc-tests"; }
refuse() {
  expected=$1
  status=0
  run > "$t/log" 2>&1 || status=$?
  [ "$status" -eq "$expected" ] || { cat "$t/log"; echo "expected $expected, got $status"; exit 1; }
}
refuse 1 # An empty suite must not silently pass.
cat > test-suite/misc/soma_existing.sh <<'SH'
set -eu
[ "$(soma)" = candidate ]
[ ! -e "$SOMA_CACHE/dirty" ]
touch "$SOMA_CACHE/dirty"
echo existing >> ran
SH
run
run # No cache state survives an invocation.
cp test-suite/misc/soma_existing.sh 'test-suite/misc/soma_added test.sh'
run
[ "$(wc -l < ran | tr -d ' ')" -eq 4 ]
printf 'exit 37\n' > 'test-suite/misc/soma_added test.sh'
refuse 37 # A changed, newly discovered test fails the command.
rm 'test-suite/misc/soma_added test.sh'
printf 'exit 42\n' >> test-suite/misc/soma_existing.sh
refuse 42 # An existing test's changed assertion also fails it.
printf 'sleep 10\n' > test-suite/misc/soma_existing.sh
SOMA_TEST_TIMEOUT=1; export SOMA_TEST_TIMEOUT
refuse 124
echo 'ok Soma test discovery, candidate binary, cache isolation, failures and timeout'
