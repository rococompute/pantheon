#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
soma run test/job_signal_facts.soma > "$T/actual"
cat > "$T/expected" <<'EXPECTED'
ok kill
ok term
ok segv
ok abrt
ok interrupt
ok negative unknown
ok positive unknown
ok exit is not a signal
ok signaled result
ok stopped result
ok timeout precedence
ok flood precedence
ok malformed tag
ok missing platform facts
ok first matching constant wins
ok actual platform constants
EXPECTED
diff -u "$T/expected" "$T/actual"
echo 'PASS job signal facts (16 exact checks)'
