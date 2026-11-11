#!/bin/bash
# M-2: the market's thresholds for n agents (test/n_agents.soma), from
# known inputs rather than running nodes, so nothing races a timer. Seven
# agents (f = 2): a merge approved at 5 approvals, rejected at 3 no votes,
# a draw at 5 reveals with 2 agents silent once the reveal window passes;
# eight agents need 6 approvals; four still need 3, and 2 no votes reject.
# test/seven-agents.sh runs seven real nodes with two killed.
#
#   test/n-agents.sh
#
# Needs soma.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-n-agents.XXXXXX")
trap 'rm -rf "$T"' EXIT
if ! soma run test/n_agents.soma > "$T/out" 2> "$T/err"; then
  echo "FAIL n-agents program failed: $(cat "$T/err" "$T/out")"; exit 1
fi
cat "$T/out"
n=$(grep -c '^ok ' "$T/out")
if grep -q '^FAIL' "$T/out" || [ "$n" -lt 25 ]; then echo "FAIL ($n of 25 ok)"; exit 1; fi
echo PASS
