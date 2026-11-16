#!/bin/sh
# integrations/standalone/pantheon-standalone end to end, with real nodes and
# a stub of docker's CLI (no Docker needed): a network made by its init;
# up starts four binary nodes in the background and the inbox server; two
# agents run in "containers" (the stub runs agent-loop.sh as docker would,
# from the run's env file, mounts and command), one is a remote agent this
# test connects with `connect --env`, and one keeps a backend of its own
# (scripted). The agents are a fake CLI that works its inbox over HTTP only:
# it drafts, reviews, attests, and bids with diffs against checkouts it
# downloads. The market merges their work. Also: the containers' sandbox
# flags and that they mount nothing of NET; tokens, env files and the
# server's config are private; /v1/status serves the market; a second up is
# refused; status; down stops every process and removes the containers.
# The unikernel path is test/integration-standalone-image.sh's.
#
# Needs main.exe (soma build main.soma), python3, curl, jq, git.
set -eu
cd "$(dirname "$0")/.."
here=$PWD
BIN=$here/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
S=$here/integrations/standalone/pantheon-standalone
t=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-standalone.XXXXXX")
NET=$t/net
remote_pid=""
cleanup() {
  [ -z "$remote_pid" ] || kill "$remote_pid" 2>/dev/null || true
  [ -d "$NET/.standalone" ] && PANTHEON=$BIN DOCKER=$t/bin/docker STUB_DIR=$t "$S" down "$NET" >/dev/null 2>&1 || true
  if [ -n "${KEEP:-}" ]; then echo "kept $t"; else rm -rf "$t"; fi
}
trap cleanup EXIT HUP INT TERM
fail() { echo "FAIL: $*"; for f in "$NET"/claude/node.log "$NET/.standalone/inbox.log" "$t"/pantheon-*.log; do [ -f "$f" ] && { echo "--- $f"; tail -12 "$f"; }; done; exit 1; }
mkdir -p "$t/bin"

# a docker that runs a "container" as a local process in a session of its
# own: its environment only what --env-file and -e give, its home its own,
# its command with the mounts' targets mapped back to their sources
cat > "$t/bin/docker" <<'STUB'
#!/usr/bin/env python3
import json, os, signal, subprocess, sys
t = os.environ["STUB_DIR"]; a = sys.argv[1:]
open(t + "/ledger", "a").write(json.dumps(a) + "\n")
cmd = a[0] if a else ""
pidf = lambda n: os.path.join(t, n + ".pid")
def pid_of(n):
    try: return int(open(pidf(n)).read())
    except (OSError, ValueError): return None
if cmd == "info": sys.exit(0)
if cmd == "rm":
    p = pid_of(a[-1])
    if p is None: sys.exit(1)
    try: os.killpg(p, signal.SIGTERM)
    except OSError: pass
    os.remove(pidf(a[-1])); print(a[-1]); sys.exit(0)
if cmd == "inspect":
    p = pid_of(a[-1])
    try: os.kill(p, 0); print("running")
    except (OSError, TypeError): print("exited")
    sys.exit(0)
if cmd == "run":
    i, name, env, mounts = 1, None, {}, {}
    while i < len(a) and a[i].startswith("-"):
        o = a[i]
        if o.startswith("--") and "=" in o or o in ("-d", "--read-only"): i += 1; continue
        v = a[i + 1]
        if o == "--name": name = v
        elif o == "-v": src, dst = v.split(":")[:2]; mounts[dst] = src
        elif o == "--env-file":
            for line in open(v):
                k, _, val = line.rstrip("\n").partition("=")
                if k: env[k] = val
        elif o == "-e": env[v] = os.environ.get(v, "")
        i += 2
    rest = [mounts.get(x, x) for x in a[i + 1:]]
    home = os.path.join(t, "home-" + name); os.makedirs(home, exist_ok=True)
    e = {"PATH": os.environ["PATH"], "HOME": home}; e.update(env)
    log = open(os.path.join(t, name + ".log"), "a")
    p = subprocess.Popen(rest, env=e, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    open(pidf(name), "w").write(str(p.pid)); print("%064x" % p.pid); sys.exit(0)
sys.exit(1)
STUB
chmod +x "$t/bin/docker"

# the fake agent CLI: works its inbox over HTTP for a while, then ends its
# session (agent-loop starts another). A patch: the checkout downloaded, a
# file added, the diff handed in
cat > "$t/agent-cli" <<'F'
#!/bin/sh
U=$(cat "$HOME/.pantheon/url"); T=$(cat "$HOME/.pantheon/token")
api() { curl -s -H "Authorization: Bearer $T" "$@"; }
i=0
while [ $i -lt 12 ]; do
  i=$((i + 1))
  w=$(api "$U/v1/wait?seconds=5"); id=$(printf '%s' "$w" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$id" ] || continue
  kind=$(printf '%s' "$w" | jq -r .kind); p=$(printf '%s' "$w" | jq -r .prompt)
  echo "$id $kind" >> "$HOME/agent.log"
  if [ "$kind" = patch ]; then
    rm -rf "$HOME/co" && mkdir "$HOME/co" && api -o "$HOME/co.tgz" "$U/v1/checkout/$id.tar.gz" && tar -xzf "$HOME/co.tgz" -C "$HOME/co"
    ( cd "$HOME/co/checkout" && git init -q && git add -A && git -c user.name=a -c user.email=a@a commit -qm head \
      && n=$(ls hello*.sh 2>/dev/null | wc -l | tr -d ' ') && printf 'echo hello %s from %s\n' "$n" "$PANTHEON_AGENT" > "hello$n.sh" \
      && git add -A && git diff --cached > "$HOME/change.diff" )
    jq -n --rawfile d "$HOME/change.diff" --arg n "hello from $PANTHEON_AGENT" '{note: $n, diff: $d}' | api --data-binary @- "$U/v1/done/$id" >/dev/null
  else
    case "$p" in
      *"choosing the next task"*) r='{"task": "add a hello command", "repo": "calc", "context": ["calc.sh"]}' ;;
      *"reviewing the bids"*) n=$(printf '%s' "$p" | sed -n 's/^Bid \([0-9]*\) by.*/\1/p' | head -1); r="{\"merge\": ${n:-0}, \"reject\": [], \"done\": false}" ;;
      *"proposed merge is safe"*) r='{"approve": true, "reason": "fine"}' ;;
      *) r='{}' ;;
    esac
    printf '%s' "$r" | api --data-binary @- "$U/v1/reply/$id" >/dev/null
  fi
done
F
chmod +x "$t/agent-cli"

mkdir -p "$t/src" && cp -R examples/calc/. "$t/src/"
(cd "$t/src" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm genesis)
printf -- '- add a hello command\n' > "$t/goal.txt"
port=$((27100 + $$ % 400 * 5))
inbox=$((28800 + $$ % 400))
export PANTHEON=$BIN DOCKER=$t/bin/docker STUB_DIR=$t DIPLOMAT_CLI=$t/agent-cli AGENT_PAUSE=1

"$S" init "$NET" --repo calc="$t/src" --base-port "$port" --block-ms 200 \
  --param term_blocks=30 --param max_merges=1 --param bid_cooldown=2 > "$t/init.out" 2>&1 || { cat "$t/init.out"; fail "init"; }
for a in claude codex grok muse; do [ -f "$NET/$a/genesis.json" ] || fail "init made no genesis for $a"; done
echo "ok init made a network of four"

"$S" up "$NET" --docker "claude codex" --backends muse=scripted --inbox "127.0.0.1:$inbox" \
  --docker-url "http://127.0.0.1:$inbox" --pass-env AGENT_PAUSE -- --goal "$t/goal.txt" --bid-window 6 > "$t/up.out" 2>&1 \
  || { cat "$t/up.out"; fail "up"; }
grep -q 'waiting for their agents: grok' "$t/up.out" || { cat "$t/up.out"; fail "up didn't say grok waits for its agent"; }
echo "ok up started four nodes, the inbox server and two containers"

# the containers: sandboxed, and nothing of NET mounted
run=$(grep '^\["run"' "$t/ledger" | head -1)
for flag in --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=512 --read-only --memory=4g; do
  printf '%s' "$run" | grep -q -- "\"$flag\"" || fail "a container runs without $flag: $run"
done
printf '%s' "$run" | jq -r '. as $a | range(length) | select($a[.] == "-v") | $a[. + 1]' | grep -F "$NET" && fail "a container mounts part of NET: $run"
printf '%s' "$run" | grep -q '"-e", "AGENT_PAUSE"' || fail "--pass-env didn't pass AGENT_PAUSE: $run"
grep -q 'PANTHEON_TOKEN' "$t/ledger" && fail "a token is on docker's command line"
for f in "$NET/.standalone/inbox.json" "$NET/.standalone/claude/token" "$NET/.standalone/claude/agent.env"; do
  [ "$(ls -l "$f" | cut -c1-10)" = "-rw-------" ] || fail "$f isn't private: $(ls -l "$f")"
done
echo "ok the containers are sandboxed and see nothing of NET; tokens, env files and the inbox's config are private"

# a second up while it runs is refused
if "$S" up "$NET" > "$t/up2.out" 2>&1; then fail "a second up ran"; fi
grep -q 'running already' "$t/up2.out" || fail "a second up said: $(cat "$t/up2.out")"

# the remote agent: connected with what connect gives
"$S" connect "$NET" grok > "$t/connect.out"
grep -q '/v1/instructions' "$t/connect.out" || fail "connect gave no prompt: $(cat "$t/connect.out")"
"$S" connect "$NET" grok --env > "$t/grok.env"
mkdir -p "$t/home-grok"
env -i PATH="$PATH" HOME="$t/home-grok" AGENT_CLI="$t/agent-cli" AGENT_PAUSE=1 $(cat "$t/grok.env") \
  sh integrations/standalone/agent-loop.sh > "$t/pantheon-grok-remote.log" 2>&1 &
remote_pid=$!
echo "ok the remote agent connected with connect --env"

# the market as an agent's token sees it
U=http://127.0.0.1:$inbox
tok=$(sed -n 's/^PANTHEON_TOKEN=//p' "$t/grok.env")
n=0
until curl -sf -H "Authorization: Bearer $tok" "$U/v1/status" | jq -e '.height != null' >/dev/null 2>&1; do
  n=$((n + 1)); [ $n -lt 30 ] || fail "/v1/status never served the market"; sleep 1
done
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/v1/status")" = 401 ] || fail "/v1/status answered without a token"
echo "ok /v1/status serves the market to an agent's token, and to no one else"

merged() { n=$(grep -c '\[merged\]' "$NET/claude/status.txt" 2>/dev/null); echo "${n:-0}"; }
# transactions of a kind an agent signed, in claude's blocks
signed_by() { grep -o "{\\\\\"agent\\\\\":\\\\\"$1\\\\\",[^}]*\\\\\"fields\\\\\":\[\\\\\"$2\\\\\"" "$NET/claude/blocks.log" 2>/dev/null | wc -l | tr -d ' '; }
n=0
until [ "$(merged)" -ge 2 ] && [ "$(( $(signed_by claude bid) + $(signed_by codex bid) ))" -ge 1 ] && [ "$(signed_by grok bid)" -ge 1 ]; do
  sleep 1; n=$((n + 1))
  [ $n -lt 300 ] || { cat "$NET/claude/status.txt" 2>/dev/null; fail "in 300 s: $(merged) merges; bids by claude $(signed_by claude bid), codex $(signed_by codex bid), grok $(signed_by grok bid)"; }
done
echo "ok the market merged $(merged) times in $n s, with bids from the containers ($(signed_by claude bid) claude, $(signed_by codex bid) codex) and the remote agent ($(signed_by grok bid))"
cat "$t"/home-pantheon-*/agent.log 2>/dev/null | grep -q patch || fail "no container got a patch request"

"$S" status "$NET" > "$t/status.out"
grep -q 'claude .*h[0-9].*binary, up.*agent in container (running)' "$t/status.out" || { cat "$t/status.out"; fail "status doesn't show claude's container"; }
grep -q 'grok .*agent remote' "$t/status.out" || { cat "$t/status.out"; fail "status doesn't show grok as remote"; }
grep -q 'muse .*backend of its own' "$t/status.out" || { cat "$t/status.out"; fail "status doesn't show muse's backend"; }
echo "ok status shows each node and where its agent runs"

"$S" down "$NET" > "$t/down.out" 2>&1 || { cat "$t/down.out"; fail "down"; }
sleep 1
pgrep -f -- "node $NET/" >/dev/null && fail "a node outlived down"
pgrep -f -- "inbox-http.py serve $NET/" >/dev/null && fail "the inbox server outlived down"
ls "$t"/pantheon-*.pid >/dev/null 2>&1 && fail "a container outlived down"
grep -q '^\["rm", "-f", "pantheon-[0-9]*-claude"\]' "$t/ledger" || fail "down didn't remove claude's container"
echo "ok down stopped the nodes, the inbox server and the containers"
echo 'PASS pantheon-standalone: nodes that only coordinate, agents over HTTP in containers and remote'
