#!/bin/bash
# Parallel tasks and stale bids (test/parallel_tasks.soma): up to
# max_open_tasks open at once, the leader drafting another while there's
# room; a bid on an earlier version taken while its edits apply line by line;
# a whole-file edit of a changed file refused or cleared; the leader clearing
# a conflicting bid without counting a rejection; fresh tries once the
# version moves.
#
#   test/parallel-tasks.sh
#
# Needs soma.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-parallel.XXXXXX")
trap 'rm -rf "$T"' EXIT
if ! soma run test/parallel_tasks.soma > "$T/out" 2> "$T/err"; then
  echo "FAIL parallel-tasks program failed: $(cat "$T/err" "$T/out")"; exit 1
fi
cat "$T/out"
n=$(grep -c '^ok ' "$T/out")
if grep -q '^FAIL' "$T/out" || [ "$n" -lt 20 ]; then echo "FAIL ($n of 20 ok)"; exit 1; fi
echo PASS
