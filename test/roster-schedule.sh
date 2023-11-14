#!/bin/sh
# M-3 part: the roster by height on fixed inputs (test/roster_schedule.soma).
set -eu
cd "$(dirname "$0")/.."
roster_schedule_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-roster-schedule.XXXXXX")
trap 'rm -rf "$roster_schedule_dir"' EXIT HUP INT TERM
if ! timeout 300 soma run test/roster_schedule.soma > "$roster_schedule_dir/out" 2> "$roster_schedule_dir/log"; then
  cat "$roster_schedule_dir/log" "$roster_schedule_dir/out"
  exit 1
fi
cat "$roster_schedule_dir/out"
if grep -q '^FAIL ' "$roster_schedule_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$roster_schedule_dir/out")" -eq 12 ]
echo 'PASS roster schedule'
