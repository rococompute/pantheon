#!/bin/bash
# M-2 at five and six agents (test/roster_sizes.soma): the network's current
# six-agent genesis and the size below it, from known inputs through the
# market's own transactions, so nothing races a timer.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-roster-sizes.XXXXXX")
trap 'rm -rf "$T"' EXIT
if ! soma run test/roster_sizes.soma > "$T/out" 2> "$T/log"; then
  echo "FAIL roster-sizes program: $(cat "$T/log" "$T/out")"; exit 1
fi
cat "$T/out"
n=$(grep -c '^ok ' "$T/out")
if grep -q '^FAIL' "$T/out" || [ "$n" -ne 19 ]; then echo "FAIL ($n of 19 ok)"; exit 1; fi
echo PASS
