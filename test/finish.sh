#!/bin/bash
# A finishing market (genesis --param finish=1): once every agent, as leader,
# finds no task to post with none open, the market is finished and every node
# stops on its own, with status 0. Without finish=1 the same network keeps
# running after its goal is met. Real node processes, scripted agents.
#
# Needs main.exe: build it with `soma build main.soma`.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-finish.XXXXXX")
AGENTS="claude codex grok muse"
fail() { echo "FAIL finish: $*"; for a in $AGENTS; do kill -9 "$(cat "$ROOT"/*/"$a"/pid 2>/dev/null)" 2>/dev/null; done; echo "logs in $ROOT"; exit 1; }

mkdir -p "$ROOT/calc" && cp -R examples/calc/. "$ROOT/calc/"
(cd "$ROOT/calc" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm calc)

# up NAME PORT [param=value...]: a network with a two-step goal, its nodes started
up() {
  name=$1 port=$2; shift 2
  dir=$ROOT/$name args=""
  for p in "$@"; do args="$args --param $p"; done
  "$BIN" init "$dir" --repo calc="$ROOT/calc" --base-port "$port" --block-ms 200 --param stall_blocks=20 $args > "$ROOT/$name.init.log" 2>&1 \
    || fail "$name: init: $(tail -2 "$ROOT/$name.init.log")"
  printf -- '- add a sub command\n- add a mul command\n' > "$dir/goal.txt"
  for a in $AGENTS; do
    "$BIN" node "$dir/$a" --goal "$dir/goal.txt" --bid-window 6 >> "$dir/$a/node.log" 2>&1 &
    echo $! > "$dir/$a/pid"
  done
}
merged() { grep -c '\[merged\]' "$ROOT/$1/$2/status.txt" 2>/dev/null || echo 0; }

up finishing 27900 finish=1
up standing 27950

# the finishing network: both tasks merge, then every node exits 0 by itself
for a in $AGENTS; do
  pid=$(cat "$ROOT/finishing/$a/pid") t=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1; t=$((t + 1)); [ $t -lt 300 ] || fail "finishing: $a's node still running after 300s: $(tail -3 "$ROOT/finishing/$a/node.log" | cut -c1-160)"
  done
  wait "$pid"; code=$?
  [ "$code" = 0 ] || fail "finishing: $a's node exited $code: $(tail -3 "$ROOT/finishing/$a/node.log" | cut -c1-160)"
  grep -q '^finished: every agent, as leader, found no more tasks' "$ROOT/finishing/$a/status.txt" || fail "finishing: $a's status doesn't say finished: $(cat "$ROOT/finishing/$a/status.txt")"
  grep -q 'the market finished at height' "$ROOT/finishing/$a/node.log" || fail "finishing: $a's log doesn't say why it stopped"
  [ "$(merged finishing "$a")" -ge 2 ] || fail "finishing: $a stopped with $(merged finishing "$a") merges, not 2"
done
echo "ok a finishing market's nodes all stop with status 0 once every leader finds no more tasks"
for a in codex grok muse; do
  n=$(wc -l < "$ROOT/finishing/$a/blocks.log") m=$(wc -l < "$ROOT/finishing/claude/blocks.log"); k=$(( n < m ? n : m ))
  cmp -s <(head -n "$k" "$ROOT/finishing/$a/blocks.log") <(head -n "$k" "$ROOT/finishing/claude/blocks.log") || fail "finishing: $a and claude disagree on a block"
done
echo "ok its nodes agree on every block"

# the standing network: its goal met as well, its nodes still run, no agent says finish
t=0
until [ "$(merged standing claude)" -ge 2 ]; do sleep 1; t=$((t + 1)); [ $t -lt 300 ] || fail "standing: 2 merges didn't land"; done
sleep 15
for a in $AGENTS; do kill -0 "$(cat "$ROOT/standing/$a/pid")" 2>/dev/null || fail "standing: $a's node stopped without finish=1"; done
! grep -qE '^(finished|no more tasks)' "$ROOT/standing/claude/status.txt" || fail "standing: a market without finish=1 counts finish votes"
for a in $AGENTS; do kill "$(cat "$ROOT/standing/$a/pid")" 2>/dev/null; done; wait 2>/dev/null
echo "ok without finish=1, a market whose goal is met keeps running"

rm -rf "$ROOT"
echo "PASS finish: a market with finish=1 stops once every leader finds no more tasks; without it, it runs on"
