#!/bin/bash
# End-to-end tests: real node processes on localhost, scripted agents, and
# injected faults. Each scenario checks that the honest nodes agree on every
# block and every file, and that work still lands.
#
#   test/e2e.sh            all scenarios, in parallel
#   test/e2e.sh crash      one scenario
#
# Needs main.exe: build it with `soma build main.soma`.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
ROOT=${TMPDIR:-/tmp}/pantheon-e2e-$$
mkdir -p "$ROOT"
AGENTS="claude codex grok muse"

# start NAME PORT [param=value...]: a fresh network, not yet running
init() {
  name=$1 port=$2; shift 2
  dir=$ROOT/$name
  args=""
  for p in "$@"; do args="$args --param $p"; done
  "$BIN" init "$dir" --seed-dir examples/calc --base-port "$port" --block-ms 200 $args >/dev/null 2>&1 || { echo "$name: init failed"; return 1; }
  printf -- '- add a sub command\n- add a mul command\n- add a div command\n- add a mod command\n' > "$dir/goal.txt"
}

# node NAME AGENT [env...] -- [flags...]
node() {
  name=$1 a=$2; shift 2
  envs=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs="$envs $1"; shift; done
  [ $# -gt 0 ] && shift
  dir=$ROOT/$name
  env $envs "$BIN" node "$dir/$a" --goal "$dir/goal.txt" --bid-window 6 "$@" >> "$dir/$a/node.log" 2>&1 &
  echo $! > "$dir/$a/pid"
}

stop() { for a in $AGENTS; do [ -f "$ROOT/$1/$a/pid" ] && kill -9 "$(cat "$ROOT/$1/$a/pid")" 2>/dev/null; done; return 0; }
kill_node() { kill -9 "$(cat "$ROOT/$1/$2/pid")" 2>/dev/null; }

field() { sed -n "s/^$2 \([0-9]*\).*/\1/p" "$ROOT/$1/$3/status.txt" 2>/dev/null | head -1; }
merged() { n=$(grep -c '\[merged\]' "$ROOT/$1/$2/status.txt" 2>/dev/null); echo "${n:-0}"; }

# wait_for NAME AGENT SECONDS what test...
wait_for() {
  name=$1 a=$2 limit=$3 what=$4; shift 4
  t=0
  until "$@"; do
    sleep 1; t=$((t + 1))
    if [ $t -ge "$limit" ]; then echo "FAIL $name: timed out waiting for $what"; tail -5 "$ROOT/$name/$a/node.log" | cut -c1-200; return 1; fi
  done
}
height_at_least() { h=$(field "$1" height "$2"); [ -n "$h" ] && [ "$h" -ge "$3" ]; }
merges_at_least() { [ "$(merged "$1" "$2")" -ge "$3" ]; }

# agree NAME AGENTS...: every block both have is the same, and so is every file
agree() {
  name=$1; shift
  ref=$1; shift
  for a in "$@"; do
    n=$(wc -l < "$ROOT/$name/$a/blocks.log"); m=$(wc -l < "$ROOT/$name/$ref/blocks.log")
    k=$(( n < m ? n : m ))
    if ! cmp -s <(head -n "$k" "$ROOT/$name/$a/blocks.log") <(head -n "$k" "$ROOT/$name/$ref/blocks.log"); then
      echo "FAIL $name: $a and $ref disagree on a block"; return 1
    fi
  done
  return 0
}
agree_files() {
  name=$1; shift; ref=$1; shift
  for a in "$@"; do
    if ! diff -r "$ROOT/$name/$a/repo" "$ROOT/$name/$ref/repo" >/dev/null; then echo "FAIL $name: $a and $ref have different files"; return 1; fi
  done
}
# the leader history never repeats within three terms
rotation_ok() {
  hist=$(sed -n 's/^history //p' "$ROOT/$1/$2/status.txt")
  set -- $hist
  a=""; b=""
  for x in "$@"; do
    if [ "$x" = "$a" ] || [ "$x" = "$b" ]; then echo "FAIL rotation: $hist"; return 1; fi
    b=$a; a=$x
  done
}
# heights match within a few blocks: they progress together
in_step() { a=$(field "$1" height "$2"); b=$(field "$1" height "$3"); [ -n "$a" ] && [ -n "$b" ] && [ $((a - b)) -le 3 ] && [ $((b - a)) -le 3 ]; }

all_up() { for a in $AGENTS; do node "$1" "$a" "$@"; done; }

scenario_happy() {
  init happy 27200 term_blocks=30 max_merges=1 bid_cooldown=2 || return 1
  for a in $AGENTS; do node happy "$a"; done
  wait_for happy claude 90 "three merges" merges_at_least happy claude 3 || { stop happy; return 1; }
  sleep 2; stop happy
  agree happy claude codex grok muse && agree_files happy claude codex grok muse && rotation_ok happy claude || return 1
  grep -q 'conflicts with bid' "$ROOT/happy/claude/status.txt" || { echo "FAIL happy: nothing was cleared by a conflict"; return 1; }
  for f in work/task-1.txt work/task-2.txt work/task-3.txt; do
    [ -f "$ROOT/happy/claude/repo/$f" ] || { echo "FAIL happy: $f not merged"; return 1; }
  done
  echo "ok happy: $(field happy height claude) blocks, $(merged happy claude) merges, rotation $(sed -n 's/^history //p' "$ROOT/happy/claude/status.txt")"
}

# kill -9 a node twice, at whatever point it's at, and bring it back
scenario_crash() {
  init crash 27300 term_blocks=25 max_merges=1 bid_cooldown=2 fallback_blocks=10 || return 1
  for a in $AGENTS; do node crash "$a"; done
  wait_for crash claude 60 "a first merge" merges_at_least crash claude 1 || { stop crash; return 1; }
  for i in 1 2; do
    kill_node crash grok
    before=$(field crash height claude)
    wait_for crash claude 60 "3 of 4 to keep deciding" height_at_least crash claude $((before + 10)) || { stop crash; return 1; }
    node crash grok
    sleep 3
  done
  wait_for crash grok 90 "grok to catch up" in_step crash grok claude || { stop crash; return 1; }
  wait_for crash claude 120 "more merges after the crashes" merges_at_least crash claude 3 || { stop crash; return 1; }
  sleep 2; stop crash
  agree crash claude codex grok muse && agree_files crash claude codex grok muse || return 1
  grep -q 'replayed' "$ROOT/crash/grok/node.log" || { echo "FAIL crash: grok never replayed from disk"; return 1; }
  echo "ok crash: grok killed twice, caught up at $(field crash height grok)"
}

# one validator misbehaving at the consensus layer
scenario_byz() {
  mode=$1 port=$2
  init "byz-$mode" "$port" term_blocks=25 max_merges=1 bid_cooldown=2 fallback_blocks=10 || return 1
  for a in claude codex grok; do node "byz-$mode" "$a"; done
  node "byz-$mode" muse PANTHEON_BYZ="$mode"
  wait_for "byz-$mode" claude 150 "three merges with muse $mode" merges_at_least "byz-$mode" claude 3 || { stop "byz-$mode"; return 1; }
  sleep 2; stop "byz-$mode"
  agree "byz-$mode" claude codex grok && agree_files "byz-$mode" claude codex grok && rotation_ok "byz-$mode" claude || return 1
  # evidence the fault really reached honest nodes, so a pass means something
  case $mode in
    equivocate) grep -q 'prevote nil: proposal from muse .* is not a valid block' "$ROOT/byz-$mode"/{claude,codex,grok}/node.log \
                  || { echo "FAIL byz-$mode: no honest node ever saw muse's bad proposal"; return 1; } ;;
    silent|bad-sig) n=$(grep -c '"agent":"muse"' "$ROOT/byz-$mode/claude/blocks.log"); [ "$n" -eq 0 ] \
                  || { echo "FAIL byz-$mode: muse's transactions reached the chain, so it wasn't cut off"; return 1; } ;;
  esac
  echo "ok byz-$mode: honest nodes agree at $(field "byz-$mode" height claude), $(merged "byz-$mode" claude) merges"
}

# one agent's model is compromised (votes no on everything) or dead (silent)
scenario_bad_model() {
  behavior=$1 port=$2
  init "model-$behavior" "$port" term_blocks=30 max_merges=1 bid_cooldown=2 stall_blocks=20 fallback_blocks=8 || return 1
  for a in claude codex grok; do node "model-$behavior" "$a"; done
  node "model-$behavior" muse -- --behavior "$behavior"
  wait_for "model-$behavior" claude 150 "three merges despite muse" merges_at_least "model-$behavior" claude 3 || { stop "model-$behavior"; return 1; }
  sleep 2; stop "model-$behavior"
  agree "model-$behavior" claude codex grok muse || return 1
  echo "ok model-$behavior: $(merged "model-$behavior" claude) merges with muse's model $behavior"
}

# a bid that touches a protected file is rejected by policy, and a bid sent by
# hand by a non-leader can't post tasks
scenario_policy() {
  init policy 27800 term_blocks=200 stall_blocks=150 bid_cooldown=1 || return 1
  : > "$ROOT/policy/goal.txt"   # no goal: this test posts the only task
  # silent models: no agent starts work by itself, so the only bid is the bad
  # one. Policy runs before any model is asked, so the leader still applies it.
  for a in $AGENTS; do node policy "$a" -- --deny test.sh --behavior silent; done
  wait_for policy claude 60 "a leader" sh -c "grep -q 'leader [a-z]*$' $ROOT/policy/claude/status.txt && ! grep -q '(drawing)' $ROOT/policy/claude/status.txt" || { stop policy; return 1; }
  leader=$(sed -n 's/.*leader \([a-z]*\)$/\1/p' "$ROOT/policy/claude/status.txt")
  for a in $AGENTS; do [ "$a" != "$leader" ] && evil=$a; done
  "$BIN" tx "$ROOT/policy/$evil" post "a task from someone who isn't leading" >/dev/null
  "$BIN" tx "$ROOT/policy/$leader" post "make calc.sh print its version" >/dev/null
  wait_for policy claude 60 "the task" sh -c "grep -q '^task 1 \[open\]' $ROOT/policy/claude/status.txt" || { stop policy; return 1; }
  "$BIN" tx "$ROOT/policy/$evil" bid 1 0 "trust me" test.sh "exit 0" >/dev/null
  wait_for policy claude 60 "the policy rejection" sh -c "grep -q 'by $evil policy: test.sh is on the denied list' $ROOT/policy/claude/status.txt" || { stop policy; return 1; }
  sleep 2; stop policy
  grep -q "$evil: only the term leader posts tasks" "$ROOT/policy/claude/node.log" || { echo "FAIL policy: a non-leader's task wasn't refused"; return 1; }
  agree policy claude codex grok muse || return 1
  echo "ok policy: $evil's bid on test.sh rejected by policy, its task refused by the market"
}

# the model path end to end, with a fake model that answers like a real one
scenario_model() {
  init model 27900 term_blocks=40 max_merges=1 bid_cooldown=2 || return 1
  fake=$ROOT/model/fake-model.sh
  cat > "$fake" <<'F'
#!/bin/sh
p=$(cat)
case "$p" in
  *"choosing the next task"*) echo 'Sure! {"task": "add a hello command"}' ;;
  *"writing a patch"*) printf '```json\n{"files": [{"path": "hello.sh", "content": "echo hello\\n"}], "note": "hello"}\n```\n' ;;
  *"reviewing the bids"*) n=$(printf '%s' "$p" | sed -n 's/^Bid \([0-9]*\) by.*/\1/p' | head -1); echo "{\"merge\": $n, \"reject\": []}" ;;
  *"proposed merge is safe"*) echo '{"approve": true, "reason": "fine"}' ;;
esac
F
  chmod +x "$fake"
  printf -- 'add a hello command\n' > "$ROOT/model/goal.txt"
  for a in $AGENTS; do node model "$a" -- --backend "cmd:$fake"; done
  wait_for model claude 90 "a merge through the model path" merges_at_least model claude 1 || { stop model; return 1; }
  sleep 2; stop model
  [ "$(cat "$ROOT/model/claude/repo/hello.sh")" = "echo hello" ] || { echo "FAIL model: merged file is wrong"; return 1; }
  agree model claude codex grok muse || return 1
  echo "ok model: a fake model's JSON replies drove a merge"
}

run() {
  case "$1" in
    happy) scenario_happy ;;
    crash) scenario_crash ;;
    equivocate) scenario_byz equivocate 27400 ;;
    double-vote) scenario_byz double-vote 27450 ;;
    silent) scenario_byz silent 27500 ;;
    bad-sig) scenario_byz bad-sig 27550 ;;
    deny) scenario_bad_model deny 27600 ;;
    silent-model) scenario_bad_model silent 27650 ;;
    policy) scenario_policy ;;
    model) scenario_model ;;
    *) echo "unknown scenario $1"; return 1 ;;
  esac
}

ALL="happy crash equivocate double-vote silent bad-sig deny silent-model policy model"
want=${*:-$ALL}
pids=""
for s in $want; do (run "$s" > "$ROOT/$s.result" 2>&1; echo $? > "$ROOT/$s.code") & pids="$pids $!"; done
wait $pids
fails=0
for s in $want; do
  cat "$ROOT/$s.result"
  [ "$(cat "$ROOT/$s.code")" = 0 ] || fails=$((fails + 1))
done
if [ $fails -eq 0 ]; then echo "PASS ($ROOT)"; rm -rf "$ROOT"; else echo "$fails failed; logs in $ROOT"; exit 1; fi
