#!/bin/sh
# Wait leases reflect real process lifetime, not a provider's idle hooks.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
wait_pid=""
trap '[ -z "$wait_pid" ] || kill "$wait_pid" 2>/dev/null || true; rm -rf "$t"' EXIT HUP INT TERM
export PANTHEON_INBOX=$t
fail() { echo "FAIL $*"; exit 1; }
start_wait() {
  "$here/scripts/pantheon-inbox" wait "$1" > "$t/out" &
  wait_pid=$!
  n=0
  while [ ! -s "$t/.waiting.$wait_pid" ]; do
    n=$((n + 1)); [ "$n" -lt 100 ] || fail 'wait published no lease'
    sleep 0.02
  done
}
start_wait 2
kill -0 "$wait_pid" || fail 'lease has no live owner'
wait "$wait_pid"; wait_pid=""
[ -z "$(find "$t" -name '.waiting.*' -print)" ] || fail 'timeout left a lease'
grep -q 'no request in 2s' "$t/out" || fail 'wait did not time out normally'
echo 'ok wait timeout removes its lease'

start_wait 90
kill -TERM "$wait_pid"
rc=0; wait "$wait_pid" || rc=$?; wait_pid=""
[ "$rc" = 143 ] || fail "cancelled wait exit $rc"
[ -z "$(find "$t" -name '.waiting.*' -print)" ] || fail 'cancelled wait left a lease'
echo 'ok cancellation removes its lease'

start_wait 90
mkdir "$t/1794000000-abcd"
echo answer > "$t/1794000000-abcd/kind"
echo $(( $(date +%s) + 60 )) > "$t/1794000000-abcd/deadline"
echo 'fixture prompt' > "$t/1794000000-abcd/prompt.txt"
wait "$wait_pid"; wait_pid=""
[ -f "$t/1794000000-abcd/claimed" ] || fail 'wait did not claim the request'
[ -z "$(find "$t" -name '.waiting.*' -print)" ] || fail 'claimed request left a lease'
echo 'ok receiving a request removes its lease'
echo PASS
