#!/bin/sh
# A restart from disk (test/restart_lock.soma): the lock and valid value a
# node saved through the binary's primitives survive loading the file, a
# conflicting proposal then gets a nil prevote, and a broken snapshot is
# refused.
set -eu
cd "$(dirname "$0")/.."
restart_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-restart.XXXXXX")
trap 'rm -rf "$restart_dir"' EXIT HUP INT TERM
if ! TMPDIR="$restart_dir" timeout 300 soma run test/restart_lock.soma > "$restart_dir/out" 2> "$restart_dir/err"; then
  cat "$restart_dir/err" "$restart_dir/out"
  exit 1
fi
cat "$restart_dir/out"
! grep -q '^FAIL ' "$restart_dir/out"
[ "$(grep -c '^ok ' "$restart_dir/out")" -eq 4 ]
echo 'ok restart: lock and valid value survive disk load; conflicting proposal prevotes nil'
