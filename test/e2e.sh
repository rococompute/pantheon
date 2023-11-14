#!/bin/bash
# End-to-end tests: real node processes on localhost, scripted agents, and
# injected faults. Each scenario checks that the honest nodes agree on every
# block and every file, and that work still lands.
#
#   test/e2e.sh            all scenarios, in parallel
#   test/e2e.sh crash      one scenario
#   KEEP=1 test/e2e.sh     keep the logs of a run that passes too
#
# Needs main.exe: build it with `soma build main.soma`.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
ROOT=${TMPDIR:-/tmp}/pantheon-e2e-$$
mkdir -p "$ROOT"
AGENTS="claude codex grok muse"

# the governed repositories: git repositories made from examples/
mkrepo() {
  d=$ROOT/src/$1; mkdir -p "$d"; cp -R "$2/." "$d/"
  (cd "$d" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$1 at genesis")
}
mkrepo calc examples/calc
mkdir -p "$ROOT/notes-src" && echo "# Notes" > "$ROOT/notes-src/README.md"
mkrepo notes "$ROOT/notes-src"
REPOS="--repo calc=$ROOT/src/calc"

# start NAME PORT [param=value...]: a fresh network, not yet running
init() {
  name=$1 port=$2; shift 2
  dir=$ROOT/$name
  args=""
  for p in "$@"; do args="$args --param $p"; done
  "$BIN" init "$dir" $REPOS --base-port "$port" --block-ms 200 $args > "$ROOT/$name.init.log" 2>&1 || { echo "$name: init failed"; tail -3 "$ROOT/$name.init.log"; return 1; }
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
term_at_least() { t=$(sed -n 's/.*  term \([0-9]*\).*/\1/p' "$ROOT/$1/$2/status.txt" 2>/dev/null | head -1); [ -n "$t" ] && [ "$t" -ge "$3" ]; }
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
# every checkout is at the same commit (merges commit the same way
# everywhere), and none has diverged from the attested tree
agree_files() {
  name=$1; shift; ref=$1; shift
  for r in $(ls "$ROOT/$name/$ref/repos"); do
    want=$(git -C "$ROOT/$name/$ref/repos/$r" rev-parse HEAD)
    for a in "$@"; do
      got=$(git -C "$ROOT/$name/$a/repos/$r" rev-parse HEAD)
      [ "$got" = "$want" ] || { echo "FAIL $name: $a and $ref have $r at different commits"; return 1; }
    done
  done
  if grep -l DIVERGED "$ROOT/$name"/*/status.txt >/dev/null 2>&1; then echo "FAIL $name: a checkout diverged: $(grep -h DIVERGED "$ROOT/$name"/*/status.txt | head -1)"; return 1; fi
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
in_step() { local x y; x=$(field "$1" height "$2"); y=$(field "$1" height "$3"); [ -n "$x" ] && [ -n "$y" ] && [ $((x - y)) -le 3 ] && [ $((y - x)) -le 3 ]; }

all_up() { for a in $AGENTS; do node "$1" "$a" "$@"; done; }

scenario_happy() {
  REPOS="--repo calc=$ROOT/src/calc --repo notes=$ROOT/src/notes" init happy 27200 term_blocks=30 max_merges=1 bid_cooldown=2 || return 1
  for a in $AGENTS; do node happy "$a"; done
  wait_for happy claude 90 "three merges" merges_at_least happy claude 3 || { stop happy; return 1; }
  sleep 2; stop happy
  agree happy claude codex grok muse && agree_files happy claude codex grok muse && rotation_ok happy claude || return 1
  grep -q 'conflicts with bid' "$ROOT/happy/claude/status.txt" || { echo "FAIL happy: nothing was cleared by a conflict"; return 1; }
  # scripted leaders post tasks to the repositories in turn
  for f in calc/work/task-1.txt notes/work/task-2.txt calc/work/task-3.txt; do
    git -C "$ROOT/happy/claude/repos/${f%%/*}" cat-file -e "HEAD:${f#*/}" 2>/dev/null || { echo "FAIL happy: $f not merged"; return 1; }
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
    # a vote line cut short, as a node stopped mid-write leaves one, at a height
    # grok will vote at once it's back: it must step past it, not stop there
    [ $i = 1 ] && for h in $(seq $((before + 11)) $((before + 80))); do
      printf 'prevote/%s/0 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca49599\n' "$h"; done >> "$ROOT/crash/grok/signed.log"
    wait_for crash claude 60 "3 of 4 to keep deciding" height_at_least crash claude $((before + 10)) || { stop crash; return 1; }
    node crash grok
    sleep 3
  done
  wait_for crash grok 90 "grok to catch up" in_step crash grok claude || { stop crash; return 1; }
  wait_for crash claude 120 "more merges after the crashes" merges_at_least crash claude 3 || { stop crash; return 1; }
  sleep 2; stop crash
  agree crash claude codex grok muse && agree_files crash claude codex grok muse || return 1
  grep -q 'replayed' "$ROOT/crash/grok/node.log" || { echo "FAIL crash: grok never replayed from disk"; return 1; }
  grep -q 'a line cut short' "$ROOT/crash/grok/node.log" || { echo "FAIL crash: grok didn't notice its cut-short vote line"; return 1; }
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

# muse holds back its link on every other draw, the way a recent leader would
# to steer a draw and be repaid next term. Holding back bars it from the next
# draw, so it never leads, and the draws still finish without it.
scenario_withhold() {
  init withhold 27700 term_blocks=15 max_merges=1 bid_cooldown=2 fallback_blocks=10 reveal_window=6 || return 1
  for a in claude codex grok; do node withhold "$a"; done
  node withhold muse PANTHEON_BYZ=withhold
  wait_for withhold claude 150 "five terms" term_at_least withhold claude 5 || { stop withhold; return 1; }
  sleep 2; stop withhold
  agree withhold claude codex grok muse && agree_files withhold claude codex grok muse && rotation_ok withhold claude || return 1
  hist=$(sed -n 's/^history //p' "$ROOT/withhold/claude/status.txt")
  case " $hist " in *" muse "*) echo "FAIL withhold: muse led after holding back: $hist"; return 1 ;; esac
  n=$(sed -n 's/^count muse.held_back \([0-9]*\).*/\1/p' "$ROOT/withhold/claude/status.txt")
  [ "${n:-0}" -ge 2 ] || { echo "FAIL withhold: muse held back ${n:-0} times, expected 2 or more"; return 1; }
  grep -q 'holding back my link' "$ROOT/withhold/muse/node.log" || { echo "FAIL withhold: muse never held back"; return 1; }
  echo "ok withhold: muse held back $n times and never led, rotation $hist"
}

# muse's checks name a wrong tree: as an attestor its yes counts as a no, and
# as leader its merges are voted down. No checkout ever diverges.
scenario_bad_tree() {
  init bad-tree 27750 term_blocks=25 max_merges=1 bid_cooldown=2 fallback_blocks=10 || return 1
  for a in claude codex grok; do node bad-tree "$a"; done
  node bad-tree muse PANTHEON_BYZ=bad-tree
  wait_for bad-tree claude 150 "three merges with muse lying about trees" merges_at_least bad-tree claude 3 || { stop bad-tree; return 1; }
  sleep 2; stop bad-tree
  agree bad-tree claude codex grok muse && agree_files bad-tree claude codex grok || return 1
  grep -q "muse's yes named another tree" "$ROOT/bad-tree/claude/node.log" || grep -q "naming a wrong tree" "$ROOT/bad-tree/muse/node.log" \
    || { echo "FAIL bad-tree: muse never named a wrong tree"; return 1; }
  echo "ok bad-tree: $(merged bad-tree claude) merges, muse's wrong trees never counted, no checkout diverged"
}

# One machine per agent, the way a real network starts: each agent makes its
# keys alone, the public parts are gathered in a network directory (in real
# life, by pull request), and each agent builds genesis by itself. Every
# genesis must come out the same. Peers are found by name ("localhost"
# standing in for VPN names), nodes listen only where told, and the mirror
# pushes merges to a branch of the origin repository.
scenario_network() {
  base=$ROOT/network net=$ROOT/network/def port=27850
  mkdir -p "$net/parts" && printf -- '- add a sub command\n- add a mul command\n' > "$base/goal.txt"
  i=0
  for a in $AGENTS; do
    "$BIN" keygen "$base/$a" --name "$a" --addr "localhost:$((port + i))" > /dev/null || { echo "FAIL network: keygen $a"; return 1; }
    cp "$base/$a/public.json" "$net/parts/$a.json"; i=$((i + 1))
    if [ $i -eq 3 ]; then
      echo "{\"repos\": []}" > "$net/network.json"
      "$BIN" genesis "$base/claude" "$net" > "$base/early.log" 2>&1 && { echo "FAIL network: genesis with 3 parts"; return 1; }
      grep -q 'needs 4' "$base/early.log" || { echo "FAIL network: no clear error for 3 parts: $(cat "$base/early.log")"; return 1; }
    fi
  done
  commit=$(git -C "$ROOT/src/calc" rev-parse HEAD)
  printf '{"block_ms": 200, "params": {"term_blocks": "25", "max_merges": "1", "bid_cooldown": "2"},\n "repos": [{"name": "calc", "url": "../../src/calc", "commit": "%s"}]}\n' "$commit" > "$net/network.json"
  for a in $AGENTS; do "$BIN" genesis "$base/$a" "$net" > "$base/$a.genesis.log" 2>&1 || { echo "FAIL network: genesis for $a: $(tail -1 "$base/$a.genesis.log")"; return 1; }; done
  n=$(for a in $AGENTS; do sed -n 's/.*genesis hash \([0-9a-f]*\).*/\1/p' "$base/$a.genesis.log"; done | sort -u | wc -l)
  [ "$n" -eq 1 ] || { echo "FAIL network: agents built $n different geneses"; return 1; }
  for a in $AGENTS; do node network "$a" -- --listen 127.0.0.1; done
  wait_for network claude 120 "two merges" merges_at_least network claude 2 || { stop network; return 1; }
  sleep 2; stop network
  agree network claude codex grok muse && agree_files network claude codex grok muse || return 1
  scripts/mirror.sh "$base/claude" > "$base/mirror.log" 2>&1 || { echo "FAIL network: mirror: $(cat "$base/mirror.log")"; return 1; }
  scripts/mirror.sh "$base/grok" >> "$base/mirror.log" 2>&1 || { echo "FAIL network: a second node's mirror push conflicted: $(cat "$base/mirror.log")"; return 1; }
  [ "$(git -C "$ROOT/src/calc" rev-parse pantheon/merged)" = "$(git -C "$base/claude/repos/calc" rev-parse HEAD)" ] \
    || { echo "FAIL network: the mirror branch isn't the merged head"; return 1; }
  echo "ok network: 4 keygens, one genesis hash, peers by name, $(merged network claude) merges, mirrored to pantheon/merged"
}

# Attestors run CI in a container before voting: the calculator's tests,
# through pantheon-ci in the image deploy/Dockerfile builds (CI_IMAGE).
# Skipped when the image or docker isn't there.
scenario_ci() {
  img=${CI_IMAGE:-pantheon:dev}
  docker image inspect "$img" >/dev/null 2>&1 || { echo "ok ci: skipped, no docker image $img (build deploy/Dockerfile)"; return 0; }
  init ci 27950 term_blocks=60 max_merges=1 bid_cooldown=2 attest_window=200 || return 1
  for a in $AGENTS; do node ci "$a" -- --ci-image "$img" --ci 'pantheon-ci "sh test.sh"' --ci-memory 1g; done
  wait_for ci claude 180 "two merges checked by CI" merges_at_least ci claude 2 || { stop ci; return 1; }
  sleep 2; stop ci
  agree ci claude codex grok muse && agree_files ci claude codex grok muse || return 1
  n=$(cat "$ROOT"/ci/*/node.log | grep -c 'CI for request .*: passed')
  [ "$n" -ge 2 ] || { echo "FAIL ci: only $n CI runs passed"; grep -h 'CI for request' "$ROOT"/ci/*/node.log | head -3; return 1; }
  echo "ok ci: $(merged ci claude) merges, $n CI runs passed in $img"
}

# A bid that applies cleanly but whose merged tree fails CI: the leader's
# rejection must say CI failed, not that the edits don't apply. A fake
# ci-sandbox runs the CI command in the checkout directly, so no docker
# image is needed, and no merge can land to make a later bid stop applying.
scenario_cifail() {
  init cifail 28200 term_blocks=60 max_merges=1 bid_cooldown=2 attest_window=200 || return 1
  fake=$ROOT/cifail/fake-ci
  cat > "$fake" <<'F'
#!/bin/sh
cd "$2" || exit 2
eval "$3"
F
  chmod +x "$fake"
  for a in $AGENTS; do node cifail "$a" -- --ci-sandbox "$fake" --ci 'echo "calc is broken"; exit 1' --ci-memory 1g; done
  wait_for cifail claude 180 "a rejection for CI" sh -c "grep -q 'CI failed on the merged tree' $ROOT/cifail/claude/status.txt" || { stop cifail; return 1; }
  sleep 2; stop cifail
  if grep -q "edits don't apply" "$ROOT/cifail/claude/status.txt"; then echo "FAIL cifail: a CI failure was worded as don't apply"; return 1; fi
  agree cifail claude codex grok muse && agree_files cifail claude codex grok muse || return 1
  echo "ok cifail: a bid that applies was rejected for failing CI, in those words, and no node diverged"
}

# one agent's model is compromised (votes no on everything) or dead (silent)
scenario_bad_model() {
  behavior=$1 port=$2
  init "model-$behavior" "$port" term_blocks=30 max_merges=1 bid_cooldown=2 stall_blocks=20 fallback_blocks=8 || return 1
  for a in claude codex grok; do node "model-$behavior" "$a"; done
  node "model-$behavior" muse -- --behavior "$behavior"
  wait_for "model-$behavior" claude 150 "three merges despite muse" merges_at_least "model-$behavior" claude 3 || { stop "model-$behavior"; return 1; }
  sleep 2; stop "model-$behavior"
  agree "model-$behavior" claude codex grok muse && agree_files "model-$behavior" claude codex grok muse || return 1
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
  wait_for policy claude 60 "a leader" sh -c "grep -qs 'leader [a-z]*$' $ROOT/policy/claude/status.txt && ! grep -q '(drawing)' $ROOT/policy/claude/status.txt" || { stop policy; return 1; }
  leader=$(sed -n 's/.*leader \([a-z]*\)$/\1/p' "$ROOT/policy/claude/status.txt")
  for a in $AGENTS; do [ "$a" != "$leader" ] && evil=$a; done
  "$BIN" tx "$ROOT/policy/$evil" post "a task from someone who isn't leading" >/dev/null
  "$BIN" tx "$ROOT/policy/$leader" post "make calc.sh print its version" >/dev/null
  wait_for policy claude 60 "the task" sh -c "grep -q '^task 1 \[open\]' $ROOT/policy/claude/status.txt" || { stop policy; return 1; }
  "$BIN" tx "$ROOT/policy/$evil" bid 1 0 "trust me" test.sh "" "exit 0" >/dev/null
  wait_for policy claude 60 "the policy rejection" sh -c "grep -q 'by $evil policy: test.sh is on the denied list' $ROOT/policy/claude/status.txt" || { stop policy; return 1; }
  sleep 2; stop policy
  grep -q "$evil: only the term leader posts tasks" "$ROOT/policy/claude/node.log" || { echo "FAIL policy: a non-leader's task wasn't refused"; return 1; }
  agree policy claude codex grok muse || return 1
  echo "ok policy: $evil's bid on test.sh rejected by policy, its task refused by the market"
}

# The model path end to end, with a fake model that answers like a real one.
# As a bidder it acts like a model with tools: it edits the scratch checkout
# the shell gives it and replies with `pantheon edits`. It only does so if the
# prompt carried the task's context file, so that's tested too.
scenario_model() {
  # fallback and attest windows longer than the test: only the attestors'
  # votes can merge, so a failed attestation must be asked again
  init model 27900 term_blocks=400 max_merges=1 bid_cooldown=2 fallback_blocks=100000 attest_window=100000 || return 1
  fake=$ROOT/model/fake-model.sh
  cat > "$fake" <<'F'
#!/bin/sh
p=$(cat)
case "$p" in
  *"choosing the next task"*)
    # each node's first two drafts fail, as a flaky model's do: the leader
    # has to ask again within its term
    c=$(dirname "$0")/drafts.$PPID; n=$(cat "$c" 2>/dev/null || echo 0); echo $((n + 1)) > "$c"
    [ "$n" -ge 2 ] || { echo "I'll look at the repository first."; exit 0; }
    echo 'Sure! {"task": "add a hello command", "repo": "calc", "context": ["calc.sh"]}' ;;
  *"writing a patch"*)
    case "$p" in *"file calc.sh>>>"*"A tiny calculator"*) ;; *) echo '{"edits": []}'; exit 0 ;; esac
    cd "$PANTHEON_WORKTREE" || exit 1
    printf 'echo hello\n' > hello.sh
    sed -i.bak 's|^  \*) echo "usage|  hello) sh hello.sh ;;\n  *) echo "usage|' calc.sh && rm calc.sh.bak
    "$PANTHEON_BIN" edits . "hello command" ;;
  *"reviewing the bids"*) n=$(printf '%s' "$p" | sed -n 's/^Bid \([0-9]*\) by.*/\1/p' | head -1); echo "{\"merge\": $n, \"reject\": []}" ;;
  *"proposed merge is safe"*)
    # each node's first attestation fails (an empty reply)
    c=$(dirname "$0")/attests.$PPID; n=$(cat "$c" 2>/dev/null || echo 0); echo $((n + 1)) > "$c"
    [ "$n" -ge 1 ] || exit 0
    echo '{"approve": true, "reason": "fine"}' ;;
esac
F
  chmod +x "$fake"
  printf -- 'add a hello command\n' > "$ROOT/model/goal.txt"
  for a in $AGENTS; do node model "$a" -- --backend "cmd:$fake"; done
  wait_for model claude 90 "a merge through the model path" merges_at_least model claude 1 || { stop model; return 1; }
  sleep 2; stop model
  r=$ROOT/model/claude/repos/calc
  [ "$(git -C "$r" show HEAD:hello.sh)" = "echo hello" ] || { echo "FAIL model: hello.sh is wrong"; return 1; }
  [ "$(cd "$r" && sh calc.sh hello)" = "hello" ] || { echo "FAIL model: calc.sh hello doesn't run hello.sh"; return 1; }
  [ "$(cd "$r" && sh calc.sh add 2 3)" = "5" ] || { echo "FAIL model: calc.sh add broke"; return 1; }
  agree model claude codex grok muse && agree_files model claude codex grok muse || return 1
  echo "ok model: a fake model with tools edited a checkout, and its edits merged on every node, though its first drafts and attestations failed"
}

scenario_stuck() {
  init stuck 27950 term_blocks=600 task_rejects=2 bid_cooldown=2 || return 1
  fake=$ROOT/stuck/fake-model.sh
  cat > "$fake" <<'F'
#!/bin/sh
p=$(cat)
case "$p" in
  *"choosing the next task"*)
    # the first task can't be done; once it's closed unfinished, the next goal
    case "$p" in *"closed unfinished"*"do the impossible"*|*"do the impossible"*"closed unfinished"*)
      echo '{"task": "add a sub command", "repo": "calc", "context": ["calc.sh"]}' ;;
    *) echo '{"task": "do the impossible", "repo": "calc", "context": ["calc.sh"]}' ;; esac ;;
  *"writing a patch"*)
    cd "$PANTHEON_WORKTREE" || exit 1
    printf 'attempt\n' > "attempt-$$.txt"
    "$PANTHEON_BIN" edits . "an attempt" ;;
  *"reviewing the bids"*)
    case "$p" in
      *"do the impossible"*) bids=$(printf '%s' "$p" | sed -n 's/^Bid \([0-9]*\) by.*/\1/p' | tr '\n' ' ')
        r=""; for b in $bids; do r="$r${r:+,}{\"bid\": $b, \"reason\": \"it can't be done\"}"; done
        echo "{\"merge\": 0, \"reject\": [$r]}" ;;
      *) n=$(printf '%s' "$p" | sed -n 's/^Bid \([0-9]*\) by.*/\1/p' | head -1); echo "{\"merge\": $n, \"reject\": []}" ;;
    esac ;;
  *"proposed merge is safe"*) echo '{"approve": true, "reason": "fine"}' ;;
esac
F
  chmod +x "$fake"
  for a in $AGENTS; do node stuck "$a" -- --backend "cmd:$fake"; done
  wait_for stuck claude 120 "a second task after the first was closed unfinished" \
    sh -c "grep -q '^task 2 .*add a sub command' '$ROOT/stuck/claude/status.txt'" || { stop stuck; return 1; }
  stop stuck
  grep -q '^task 1 \[closed\]' "$ROOT/stuck/claude/status.txt" || { echo "FAIL stuck: task 1 isn't closed"; return 1; }
  grep -E '^bid [0-9]+ \[merged\] task 1 ' "$ROOT/stuck/claude/status.txt" && { echo "FAIL stuck: task 1 merged a bid"; return 1; }
  agree stuck claude codex grok muse || return 1
  echo "ok stuck: a task no bid could do was closed unfinished, and the leader drafted the next"
}

scenario_limit() {
  init limit 28000 term_blocks=400 max_merges=1 bid_cooldown=2 || return 1
  fake=$ROOT/limit/fake-model.sh
  cat > "$fake" <<'F'
#!/bin/sh
p=$(cat)
# each node's first two calls hit a subscription limit, as Claude Code says it:
# the message, then when it resets
c=$(dirname "$0")/calls.$PPID; n=$(cat "$c" 2>/dev/null || echo 0); echo $((n + 1)) > "$c"
[ "$n" -ge 2 ] || { echo "Claude AI usage limit reached|$(( $(date +%s) + 4 ))"; exit 0; }
case "$p" in
  *"choosing the next task"*) echo '{"task": "add a hello command", "repo": "calc", "context": ["calc.sh"]}' ;;
  *"writing a patch"*)
    cd "$PANTHEON_WORKTREE" || exit 1
    printf 'echo hello\n' > hello.sh
    "$PANTHEON_BIN" edits . "hello command" ;;
  *"reviewing the bids"*) n=$(printf '%s' "$p" | sed -n 's/^Bid \([0-9]*\) by.*/\1/p' | head -1); echo "{\"merge\": $n, \"reject\": []}" ;;
  *"proposed merge is safe"*) echo '{"approve": true, "reason": "fine"}' ;;
esac
F
  chmod +x "$fake"
  printf -- 'add a hello command\n' > "$ROOT/limit/goal.txt"
  for a in $AGENTS; do node limit "$a" -- --backend "cmd:$fake"; done
  wait_for limit claude 120 "a merge after the model's limit" merges_at_least limit claude 1 || { stop limit; return 1; }
  stop limit
  grep -q 'LIMIT: ' "$ROOT/limit/claude/node.log" || { echo "FAIL limit: the limit wasn't noticed"; return 1; }
  if grep 'model call failed' "$ROOT"/limit/*/node.log | grep -q 'usage limit'; then echo "FAIL limit: a limited call counted as a failure"; return 1; fi
  agree limit claude codex grok muse || return 1
  echo "ok limit: calls that hit a usage limit were held until it reset, not failed, and the market merged"
}

# A model CLI that writes its limit to stderr and nothing to stdout, as Grok
# Build does, through the real scripts/bidder-grok.sh: the node must see a
# limit and hold its calls, not read an empty reply and count a failure.
scenario_limit_cli() {
  init limit-cli 28150 term_blocks=400 || return 1
  mkdir -p "$ROOT/limit-cli/bin"
  cat > "$ROOT/limit-cli/bin/grok" <<'F'
#!/bin/sh
printf 'Error: Internal error: {\n  "message": "API error (status 402 Payment Required): Grok Build usage balance exhausted",\n  "http_status": 402\n}\n' >&2
exit 1
F
  chmod +x "$ROOT/limit-cli/bin/grok"
  for a in $AGENTS; do node limit-cli "$a" PATH="$ROOT/limit-cli/bin:$PATH" -- --backend "cmd:$PWD/scripts/bidder-grok.sh"; done
  # only a leader asks its model, for a draft: any node's LIMIT will do
  wait_for limit-cli claude 60 "the limit noticed" sh -c "cat '$ROOT'/limit-cli/*/node.log | grep -q 'LIMIT: .*balance exhausted'" || { stop limit-cli; return 1; }
  stop limit-cli
  if grep -q 'model call failed' "$ROOT"/limit-cli/*/node.log; then echo "FAIL limit-cli: a limited call counted as a failure"; grep 'model call failed' "$ROOT"/limit-cli/*/node.log | head -2; return 1; fi
  echo "ok limit-cli: a CLI's limit on stderr reached the node through bidder.sh, and its calls were held"
}

scenario_prune() {
  # settled bids pruned almost at once: bid numbers must still never repeat
  init prune 28050 term_blocks=30 max_merges=2 bid_cooldown=2 keep_settled=2 || return 1
  for a in $AGENTS; do node prune "$a"; done
  # every half second, whether two live bids share a number
  ( while [ ! -f "$ROOT/prune/done" ]; do
      d=$(sed -n 's/^bid \([0-9]*\) .*/\1/p' "$ROOT/prune/claude/status.txt" 2>/dev/null | sort | uniq -d | head -1)
      [ -n "$d" ] && echo "$d" >> "$ROOT/prune/reused"; sleep 0.5; done ) &
  wait_for prune claude 150 "bids pruned and merges going on" sh -c "[ \$(grep -c 'merged bid' '$ROOT/prune/claude/node.log') -ge 4 ]" || { touch "$ROOT/prune/done"; stop prune; return 1; }
  touch "$ROOT/prune/done"; sleep 1; stop prune
  [ ! -s "$ROOT/prune/reused" ] || { echo "FAIL prune: two live bids shared a number: $(sort -u "$ROOT/prune/reused" | tr '\n' ' ')"; return 1; }
  n=$(grep -o 'merged bid [0-9]*' "$ROOT"/prune/claude/node.log | sort | uniq -d)
  [ -z "$n" ] || { echo "FAIL prune: a bid number merged twice: $n"; return 1; }
  agree prune claude codex grok muse || return 1
  echo "ok prune: bids pruned from the state, and every bid's number still its own"
}

scenario_epoch() {
  # a new epoch's genesis is an earlier chain's merge commit, with that
  # chain's Pantheon-Version: this chain's first merges must still apply
  d=$ROOT/src/calc-epoch; mkdir -p "$d"; cp -R examples/calc/. "$d/"
  (cd "$d" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "Merge bid 64 for task 14 by muse

an earlier chain's merge

Pantheon-Version: 9
Pantheon-Bid: 64")
  REPOS="--repo calc=$d" init epoch 28100 term_blocks=40 max_merges=1 bid_cooldown=2 || return 1
  for a in $AGENTS; do node epoch "$a"; done
  wait_for epoch claude 90 "a merge in the new chain" merges_at_least epoch claude 1 || { stop epoch; return 1; }
  sleep 3; stop epoch
  grep -q 'merged bid' "$ROOT/epoch/claude/node.log" || { echo "FAIL epoch: the merge was decided but never applied to the checkout"; return 1; }
  want=$(sed -n 's/^repo calc \([0-9a-f]*\).*/\1/p' "$ROOT/epoch/claude/status.txt")
  have=$(git -C "$ROOT/epoch/claude/repos/calc" rev-parse HEAD^{tree})
  [ "$want" = "$have" ] || { echo "FAIL epoch: the checkout's tree $have isn't the market's $want"; return 1; }
  agree epoch claude codex grok muse && agree_files epoch claude codex grok muse || return 1
  echo "ok epoch: a genesis carrying an earlier chain's version, and this chain's merges still applied"
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
    withhold) scenario_withhold ;;
    bad-tree) scenario_bad_tree ;;
    network) scenario_network ;;
    ci) scenario_ci ;;
    cifail) scenario_cifail ;;
    policy) scenario_policy ;;
    model) scenario_model ;;
    stuck) scenario_stuck ;;
    limit) scenario_limit ;;
    limit-cli) scenario_limit_cli ;;
    prune) scenario_prune ;;
    epoch) scenario_epoch ;;
    *) echo "unknown scenario $1"; return 1 ;;
  esac
}

ALL="happy crash equivocate double-vote silent bad-sig withhold bad-tree deny silent-model policy model stuck limit limit-cli prune epoch network ci cifail"
want=${*:-$ALL}
pids=""
for s in $want; do (run "$s" > "$ROOT/$s.result" 2>&1; echo $? > "$ROOT/$s.code") & pids="$pids $!"; done
wait $pids
fails=0
for s in $want; do
  cat "$ROOT/$s.result"
  [ "$(cat "$ROOT/$s.code")" = 0 ] || fails=$((fails + 1))
done
if [ $fails -eq 0 ]; then echo "PASS ($ROOT)"; [ -n "${KEEP:-}" ] || rm -rf "$ROOT"; else echo "$fails failed; logs in $ROOT"; exit 1; fi
