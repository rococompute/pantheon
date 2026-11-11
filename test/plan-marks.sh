#!/bin/bash
# The leader's mark on a long plan line (test/plan_marks.soma): a line the
# leader's prompt shows cut at 400 characters is named by its start, and the
# mark marks the whole line, only where a line begins with it and only if one
# does; a pick's cut plan_line loses its ...; a task closed with its line
# still open is logged once, with why.
#
#   test/plan-marks.sh
#
# Needs soma.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-plan-marks.XXXXXX")
trap 'rm -rf "$T"' EXIT
if ! soma run test/plan_marks.soma > "$T/out" 2> "$T/err"; then
  echo "FAIL plan-marks program failed: $(cat "$T/err" "$T/out")"; exit 1
fi
cat "$T/out"
n=$(grep -c '^ok ' "$T/out")
if grep -q '^FAIL' "$T/out" || [ "$n" -lt 16 ]; then echo "FAIL ($n of 16 ok)"; exit 1; fi
echo PASS
