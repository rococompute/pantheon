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
unset SOMA_TEST_TIMEOUT
# Named tests: only those run (Soma's CI names what a bid adds or changes)
printf 'echo one >> ran\n' > test-suite/misc/soma_one.sh
printf 'exit 9\n' > test-suite/misc/soma_two.sh
: > ran
sh "$here/scripts/soma-misc-tests" test-suite/misc/soma_one.sh > "$t/log" 2>&1 || { cat "$t/log"; echo "a named test failed"; exit 1; }
[ "$(cat ran)" = one ] || { echo "named: ran $(cat ran)"; exit 1; }
status=0; sh "$here/scripts/soma-misc-tests" test-suite/misc/soma_one.sh test-suite/misc/soma_two.sh > "$t/log" 2>&1 || status=$?
[ "$status" -eq 9 ] || { cat "$t/log"; echo "a failing named test gave $status"; exit 1; }
status=0; sh "$here/scripts/soma-misc-tests" bin/soma > "$t/log" 2>&1 || status=$?
[ "$status" -eq 2 ] || { echo "a name that isn't a soma_*.sh test gave $status"; exit 1; }
echo 'ok named tests: only those run, a failing one fails, other files are refused'
# --changed: what isn't in the baseline of path:hash runs, what is doesn't
printf 'echo one >> ran\n' > test-suite/misc/soma_one.sh
rm -f test-suite/misc/soma_two.sh
h1=$(git hash-object --no-filters test-suite/misc/soma_one.sh); hx=$(git hash-object --no-filters test-suite/misc/soma_existing.sh)
: > ran
sh "$here/scripts/soma-misc-tests" --changed "test-suite/misc/soma_one.sh:$h1 test-suite/misc/soma_existing.sh:$hx" > "$t/log" 2>&1 || { cat "$t/log"; exit 1; }
[ ! -s ran ] && grep -q 'no test-suite/misc/soma_\*.sh test added or changed' "$t/log" || { cat "$t/log"; echo "--changed ran an unchanged test"; exit 1; }
printf 'echo one-changed >> ran\n' > test-suite/misc/soma_one.sh
printf 'echo new >> ran\n' > test-suite/misc/soma_new.sh
sh "$here/scripts/soma-misc-tests" --changed "test-suite/misc/soma_one.sh:$h1 test-suite/misc/soma_existing.sh:$hx" > "$t/log" 2>&1 || { cat "$t/log"; exit 1; }
[ "$(sort ran | tr '\n' ' ')" = "new one-changed " ] || { echo "--changed ran: $(cat ran)"; exit 1; }
printf 'exit 5\n' > test-suite/misc/soma_new.sh
status=0; sh "$here/scripts/soma-misc-tests" --changed "test-suite/misc/soma_existing.sh:$hx" > "$t/log" 2>&1 || status=$?
[ "$status" -eq 5 ] || { cat "$t/log"; echo "a failing changed test gave $status"; exit 1; }
echo 'ok --changed: only added or changed tests run, and a failing one fails'
