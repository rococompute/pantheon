#!/bin/sh
# Waits until a local network has merged N bids or the time runs out, then stops it.
# Usage: watch-run.sh <dir> <merges> <seconds> [pantheon up args...]
dir=$1; want=$2; limit=$3; shift 3
bin=${PANTHEON_BIN:-bin/pantheon}
"$bin" up --dir "$dir" "$@" > "$dir/up.log" 2>&1 &
up=$!
start=$(date +%s)
while :; do
  sleep 15
  merged=$("$bin" status --rpc ${PANTHEON_RPC:-http://127.0.0.1:26657} --json 2>/dev/null | grep -c '"status": "merged"')
  now=$(date +%s)
  echo "t+$((now - start))s merged=$merged"
  [ "$merged" -ge "$want" ] && break
  [ $((now - start)) -ge "$limit" ] && { echo "time limit reached"; break; }
done
sleep 5
"$bin" status --rpc ${PANTHEON_RPC:-http://127.0.0.1:26657}
kill -TERM "$up"; wait "$up" 2>/dev/null
