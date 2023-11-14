#!/bin/bash
# Seven extracted nodes: genesis, work, then progress with exactly n-f alive.
# CI's added_tests discovery runs this new test after its normal command.
# KEEP=1 retains successful runs; failures always retain their diagnostics.
set -eu
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo 'build main.soma first'; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-seven.XXXXXX")
AGENTS='a b c d e f g'
LIVE='a b c d e'
pids=()
passed=
cleanup() {
  trap - EXIT
  for pid in "${pids[@]}"; do kill -CONT "$pid" 2>/dev/null || true; kill -KILL "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  if [ -n "$passed" ] && [ -z "${KEEP:-}" ]; then rm -rf "$T"; else
    echo "seven-agent logs: $T"
    for a in $AGENTS; do echo "--- $a"; tail -5 "$T/$a/node.log" 2>/dev/null || true; done
  fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM
mkdir -p "$T/net/parts" "$T/src"
cp -R examples/calc/. "$T/src/"
git -C "$T/src" init -q
git -C "$T/src" add -A
git -C "$T/src" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm genesis
commit=$(git -C "$T/src" rev-parse HEAD)
# Reserve seven distinct ephemeral localhost ports while selecting them.
ports=$(python3 - <<'PY'
import socket
ss = [socket.socket() for _ in range(7)]
for s in ss: s.bind(('127.0.0.1', 0))
print(' '.join(str(s.getsockname()[1]) for s in ss))
PY
)
set -- $ports
for a in $AGENTS; do
  "$BIN" keygen "$T/$a" --name "$a" --addr "127.0.0.1:$1" > "$T/$a.keygen.log" 2>&1
  shift
  cp "$T/$a/public.json" "$T/net/parts/$a.json"
done
cat > "$T/net/network.json" <<JSON
{"block_ms":200,"params":{"term_blocks":"45","max_merges":"1","stall_blocks":"30","bid_cooldown":"2","bid_blocks":"20","fallback_blocks":"8","attest_window":"60","reveal_window":"6"},"repos":[{"name":"calc","url":"../src","commit":"$commit"}]}
JSON
for a in $AGENTS; do
  "$BIN" genesis "$T/$a" "$T/net" > "$T/$a.genesis.log" 2>&1
  cmp "$T/a/genesis.json" "$T/$a/genesis.json"
done
for i in $(seq 1 40); do echo "- seven-agent task $i"; done > "$T/goal.txt"
for a in $AGENTS; do
  "$BIN" node "$T/$a" --goal "$T/goal.txt" --bid-window 6 --listen 127.0.0.1 > "$T/$a/node.log" 2>&1 &
  pids+=("$!")
done
# One overall deadline leaves time for cleanup under CI's 600-second limit.
deadline=$((SECONDS + 480))
wait_until() {
  local what=$1; shift
  until "$@"; do
    if [ "$SECONDS" -ge "$deadline" ]; then echo "FAIL seven: waiting for $what"; exit 1; fi
    sleep 1
  done
}
version() { sed -n 's/^version //p' "$T/$1/status.txt" 2>/dev/null || true; }
term() { sed -n 's/^height .*  term \([0-9]*\).*/\1/p' "$T/a/status.txt" 2>/dev/null || true; }
all_merged() {
  local a v
  for a in $AGENTS; do v=$(version "$a"); [ "${v:-0}" -ge 1 ] || return 1; done
}
wait_until 'all seven to merge' all_merged
# Stop two real validators, reap them, and record a conservative baseline
# after the kill. Two later terms guarantee a draw that began after it.
kill -KILL "${pids[5]}" "${pids[6]}"
wait "${pids[5]}" 2>/dev/null || true
wait "${pids[6]}" 2>/dev/null || true
pids=("${pids[@]:0:5}")
before=$(version a)
start_term=$(term)
f_before=$(sed -n 's/^count f.held_back //p' "$T/a/status.txt")
g_before=$(sed -n 's/^count g.held_back //p' "$T/a/status.txt")
f_before=${f_before:-0}
g_before=${g_before:-0}
progress() {
  local a v t missed
  t=$(term)
  [ "${t:-0}" -ge "$((start_term + 2))" ] || return 1
  for a in $LIVE; do
    v=$(version "$a"); [ "${v:-0}" -gt "$before" ] || return 1
    # Both absent agents missed at least two draws. With only five alive,
    # these completed draws necessarily used exactly n-f = 5 reveals.
    for dead in f g; do
      v=$(sed -n "s/^count $dead.held_back //p" "$T/$a/status.txt")
      if [ "$dead" = f ]; then missed=$f_before; else missed=$g_before; fi
      [ "${v:-0}" -ge "$((missed + 2))" ] || return 1
    done
  done
}
wait_until 'a further merge and two draws with five survivors' progress
# Freeze processes to inspect a stable snapshot. Retry if a merge was in
# flight; checkouts must match exactly, not merely be adjacent commits.
snapshot() {
  local pid result=0
  for pid in "${pids[@]}"; do kill -STOP "$pid"; done
  python3 - "$T" <<'PY' || result=$?
import json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
def git(a, *args):
    return subprocess.check_output(['git', '-C', str(root/a/'repos/calc'), *args], text=True).strip()
logs = {}
try:
    for a in 'abcdefg':
        logs[a] = [json.loads(l) for l in (root/a/'blocks.log').read_text().splitlines()]
except json.JSONDecodeError:
    # A process can be frozen during the append of its latest block.
    sys.exit(2)
# Every block shared by any pair, including the killed nodes, is identical.
ref = max(logs.values(), key=len)
for a, blocks in logs.items():
    assert blocks == ref[:len(blocks)], f'{a}: conflicting block history'
heads = []
ready = True
for a in 'abcde':
    status = (root/a/'status.txt').read_text()
    assert 'DIVERGED' not in status, f'{a}: diverged'
    trees = [l.split() for l in status.splitlines() if l.startswith('repo calc ')]
    if not trees or len(trees[0]) != 3:
        sys.exit(2)  # status.txt can also be in the middle of a write
    tree = trees[0][2]
    ready &= git(a, 'rev-parse', 'HEAD^{tree}') == tree
    ready &= not git(a, 'status', '--porcelain')
    heads.append(git(a, 'rev-parse', 'HEAD'))
# A different version can occur if a process was stopped during a merge.
sys.exit(0 if ready and len(set(heads)) == 1 else 2)
PY
  if [ "$result" -ne 0 ]; then
    for pid in "${pids[@]}"; do kill -CONT "$pid"; done
    [ "$result" -eq 2 ] || exit "$result"
    return 1
  fi
}
wait_until 'identical survivor checkouts' snapshot
passed=1
echo 'PASS seven: one genesis, seven nodes merged; five survivors merged and completed two draws; blocks and checkouts agree'
