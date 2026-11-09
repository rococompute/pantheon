#!/bin/sh
# A whole Pantheon network on one small Linux host, with the agents as
# diplomats: four nodes as systemd user services, and beside them, in herdr,
# one interactive session per agent that works its node's inbox. The machine
# is small and shared, so the diplomats only think, answer and judge here; real
# coding work goes to each agent's own workers on its provider's machines
# (Claude Code cloud sessions, Codex Cloud tasks, Cursor Cloud Agents), which
# start from the market's head on GitHub and hand back a branch. An agent
# whose provider has no machines of its own (Muse) gets a VM on this host
# instead, and works its inbox from in there, over HTTP on the host's
# localhost. CI runs one check at a time, in a sandbox (deploy/host/ci-sandbox).
# Nothing listens beyond localhost.
#
#   scripts/host.sh network            keys, the network and its genesis (once), for Pantheon at HEAD
#   scripts/host.sh start              write the services and (re)start them all: nodes, mirror, inbox server
#   scripts/host.sh vm AGENT           AGENT's VM (Muse's): made and started, the agent's CLI in it, a token
#   scripts/host.sh login AGENT        log AGENT's CLI in, in its VM (device code: you open the URL)
#   scripts/host.sh diplomats          from a herdr pane: a workspace with one tab per agent, each session started
#   scripts/host.sh watchdog [--check] (re)start the watchdog (--check: what it sees, nudging no one): it nudges an agent whose session stopped working its inbox
#   scripts/host.sh instructions       write each diplomat's instructions again (after changing them; restarts nothing)
#   scripts/host.sh mirror             push the market's head to GitHub now (the mirror service does it every 30s)
#   scripts/host.sh check DIR          the nodes' CI on a checkout, in the sandbox (pantheon-inbox check uses it)
#   scripts/host.sh stop               stop the nodes, the mirror and the inbox server (VMs: limactl stop)
#   scripts/host.sh status             each node's chain, limits, inbox, and the services
#   scripts/host.sh logs [AGENT]       follow a node's log (or the mirror's and the inbox server's)
#
# Everything lives in PANTHEON_HOST (default ~/pantheon): soma/ and pantheon/
# (built by scripts/setup-node.sh), net/ (the nodes' homes), inbox/ (one per
# agent), diplomats/ (each one's instructions), desk/ (each one's working
# directory), inbox.json (the inbox server's tokens, as hashes), goal.txt.
#
# Settings, from the environment:
#   VM_AGENTS     the agents that work from a VM on this host (default: muse)
#   REMOTE        the GitHub repository workers share (default: this checkout's origin)
#   CODEX_ENV     the Codex Cloud environment for codex's workers (codex cloud lists them)
#   GROK_MODEL    the Cursor CLI's model for grok (default: grok; cursor-agent models lists them)
#   SOMA_REMOTE   Soma's repository, for the agents to read (default: https://github.com/yevbar/soma.git)
#   BRANCH        the branch of REMOTE the market publishes to and workers start from (default: its default branch)
#   SOMA_REF      the branch there at the commit SOMA_DIR is built from (default: gradual, Soma's default branch)
# or from PANTHEON_HOST/host.env (lines like CODEX_ENV=soma), read first.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
P=${PANTHEON_HOST:-$HOME/pantheon}
[ ! -f "$P/host.env" ] || . "$P/host.env"
NET=$P/net AGENTS="claude codex grok muse"
VM_AGENTS=${VM_AGENTS:-muse}
BIN=$here/main.exe SOMA=${SOMA_DIR:-$P/soma}
CI_MEMORY=${CI_MEMORY:-1536m}
CI_CMD=$(python3 "$here/deploy/ci-command.py" "$here" "${PANTHEON_CI:-timeout 120 soma build main.soma && timeout 120 test/edits.sh && sh test/ci-policy.sh}")
PORT=${INBOX_PORT:-8787}
# a Lima VM (plain, user-mode network) reaches the host's localhost here
VM_HOST=192.168.5.2
REMOTE=${REMOTE:-$(git -C "$here" remote get-url origin 2>/dev/null || true)}
# the branch the market publishes to and workers start from: REMOTE's default
# branch, so the market's work is where everyone looks
BRANCH=${BRANCH:-$( [ -n "$REMOTE" ] && git ls-remote --symref "$REMOTE" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\(.*\)	HEAD$|\1|p')}
BRANCH=${BRANCH:-master}
CODEX_ENV=${CODEX_ENV:-}
GROK_MODEL=${GROK_MODEL:-grok}
SOMA_REMOTE=${SOMA_REMOTE:-https://github.com/yevbar/soma.git}
SOMA_REF=${SOMA_REF:-gradual}
soma_commit() { git -C "$SOMA" rev-parse HEAD 2>/dev/null || echo unknown; }
UNITS=$HOME/.config/systemd/user
export PATH="$HOME/.local/bin:$PATH"
say() { printf 'host: %s\n' "$*"; }
die() { printf 'host: %s\n' "$*" >&2; exit 1; }
need_bin() { [ -x "$BIN" ] || die "no $BIN: build Pantheon first (SOMA_DIR=$SOMA scripts/setup-node.sh)"; }
in_vm_agents() { case " $VM_AGENTS " in *" $1 "*) return 0 ;; esac; return 1; }
is_agent() { case " $AGENTS " in *" $1 "*) return 0 ;; esac; return 1; }
vm() { printf 'pantheon-%s' "$1"; }
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

cmd_network() {
  need_bin
  [ ! -d "$NET" ] || die "$NET already holds a network. A new chain is a new network: stop it, move $NET away, and run this again"
  commit=$(git -C "$here" rev-parse HEAD)
  # the cloud run's parameters (examples/network/network.json): an hour's
  # term, attest window and stuck-task limit; fallback after 15 minutes
  "$BIN" init "$NET" --repo "pantheon=$here" --base-port 26701 --block-ms 1000 \
    --param term_blocks=3600 --param max_merges=2 --param stall_blocks=1800 --param attest_window=3600 \
    --param fallback_blocks=900 --param reveal_window=30 --param bid_cooldown=5
  [ -f "$P/goal.txt" ] || cp "$here/examples/cloud/goal.txt" "$P/goal.txt"
  mkdir -p "$P/inbox"; for a in $AGENTS; do mkdir -p "$P/inbox/$a"; done
  say "a network for Pantheon at $(git -C "$here" log -1 --format='%h %s' "$commit"); goals in $P/goal.txt"
  say "next: scripts/host.sh start, then scripts/host.sh vm muse, then scripts/host.sh diplomats (from a herdr pane)"
}

# the instructions a diplomat on this host follows, for its provider
render_diplomat() {
  a=$1; mkdir -p "$P/diplomats" "$P/desk/$a"
  # a plain clone of the shared repository: cloud hand-offs start from the
  # GitHub remote and branch of the directory they run in
  [ -z "$REMOTE" ] || [ -d "$P/desk/$a/pantheon/.git" ] || git clone -q "$REMOTE" "$P/desk/$a/pantheon" \
    || say "$a: can't clone $REMOTE into $P/desk/$a/pantheon: its cloud hand-offs need it"
  d=$here/deploy/host/delegate/$a.md
  # some agent CLIs (codex) give their commands only a few of their own
  # environment variables: the inbox's settings go in a wrapper instead
  cat > "$P/desk/$a/pantheon-inbox" <<W
#!/bin/sh
PANTHEON_INBOX=$P/inbox/$a PANTHEON_REMOTE=$REMOTE PANTHEON_BRANCH=$BRANCH PANTHEON_CHECK="$here/scripts/host.sh check" \\
  exec $here/scripts/pantheon-inbox "\$@"
W
  chmod 755 "$P/desk/$a/pantheon-inbox"
  python3 - "$here/deploy/host/diplomat.md" "$d" "$P/diplomats/$a.md" <<PY
import sys, os
t = open(sys.argv[1]).read()
d = open(sys.argv[2]).read() if os.path.exists(sys.argv[2]) else "## How you hand off\n\nYou have no workers elsewhere: do patches by hand, small, and skip what's too big."
t = t.replace("{{DELEGATE}}", d.strip())
# the inbox command by its full path: the wrapper with this agent's settings
t = t.replace("pantheon-inbox ", "{{DESK}}/pantheon-inbox ").replace("\`pantheon-inbox\`", "\`{{DESK}}/pantheon-inbox\`")
for k, v in {"AGENT": "$a", "REMOTE": "$REMOTE", "BRANCH": "$BRANCH", "NET": "$NET",
             "CODEX_ENV": "${CODEX_ENV:-ENV_ID}", "DESK": "$P/desk/$a",
             "SOMA_REMOTE": "$SOMA_REMOTE", "SOMA_REF": "$SOMA_REF", "SOMA_DIR": "$SOMA",
             "SOMA_COMMIT": "$(soma_commit)", "SOMA_NOTES": "$P/soma-notes.md", "GROK_MODEL": "$GROK_MODEL"}.items():
    t = t.replace("{{%s}}" % k, v)
open(sys.argv[3], "w").write(t)
PY
}

cmd_start() {
  need_bin
  [ -d "$NET" ] || die "no network yet: scripts/host.sh network"
  for a in $AGENTS; do
    # the node strips PANTHEON_* from a backend's environment: the backend sets its own
    if in_vm_agents "$a"; then url="INBOX_URL=http://$VM_HOST:$PORT "; else url=""; fi
    cat > "$NET/$a/backend.sh" <<B
#!/bin/sh
PANTHEON_INBOX=$P/inbox/$a ${url}exec $here/scripts/bidder-inbox.sh
B
    cat > "$NET/$a/run.sh" <<R
#!/bin/sh
exec $BIN node $NET/$a --backend cmd:$NET/$a/backend.sh --goal $P/goal.txt --listen 127.0.0.1 \\
  --ci-repo pantheon $(q "$CI_CMD") --ci-sandbox $here/deploy/host/ci-sandbox --ci-memory $CI_MEMORY
R
    chmod 755 "$NET/$a/backend.sh" "$NET/$a/run.sh"
    in_vm_agents "$a" || render_diplomat "$a"
  done
  mkdir -p "$UNITS"
  cat > "$UNITS/pantheon-node@.service" <<U
[Unit]
Description=Pantheon node %i
[Service]
Environment=SOMA_DIR=$SOMA
ExecStart=$NET/%i/run.sh
Restart=on-failure
RestartSec=10
[Install]
WantedBy=default.target
U
  # the market's head on GitHub, where the agents' workers start from
  cat > "$UNITS/pantheon-mirror.service" <<U
[Unit]
Description=Pantheon's merged head, pushed to $REMOTE as $BRANCH
[Service]
ExecStart=$here/scripts/host.sh mirror-loop
Restart=on-failure
RestartSec=60
[Install]
WantedBy=default.target
U
  units=""
  [ -n "$REMOTE" ] && units="pantheon-mirror.service" || say "no REMOTE (this checkout has no origin): workers elsewhere can't see the market's head"
  if [ -n "$VM_AGENTS" ]; then
    # for the VMs: on the host's localhost, which a VM reaches and nothing outside does
    [ -f "$P/inbox.json" ] || printf '{"listen": "127.0.0.1:%s", "url": "", "agents": {}}\n' "$PORT" > "$P/inbox.json"
    cat > "$UNITS/pantheon-inbox.service" <<U
[Unit]
Description=Pantheon inbox over HTTP, for the agents' VMs
[Service]
ExecStart=/usr/bin/python3 $here/scripts/inbox-http.py serve $P/inbox.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
U
    units="$units pantheon-inbox.service"
  fi
  for a in $AGENTS; do units="$units pantheon-node@$a.service"; done
  if command -v herdr >/dev/null; then write_watchdog_unit; units="$units pantheon-watchdog.service"; fi
  systemctl --user daemon-reload
  # every node at once: restarting them one by one mid-height stalls the chain
  systemctl --user enable -q $units
  systemctl --user restart $units
  say "started: $units"
  say "next: scripts/host.sh diplomats, from a herdr pane; watch it: scripts/host.sh status"
}

# the market's head (any node's: merges commit the same way on every node),
# published to BRANCH: a fast-forward, or a merge when people committed there
# too (scripts/publish.sh)
cmd_mirror() {
  [ -n "$REMOTE" ] || die "no REMOTE: set it to the GitHub repository workers share"
  r=$NET/claude/repos/pantheon
  [ -d "$r" ] || die "no network yet: scripts/host.sh network"
  QUIET=${quiet:-} PUBLISH_DIR=$P/publish "$here/scripts/publish.sh" "$r" "$REMOTE" "$BRANCH"
}
cmd_mirror_loop() { while :; do quiet=1 cmd_mirror || true; sleep 30; done; }

# The watchdog. An agent's session sometimes ends its turn (a summary, as if
# the job were done) while its node keeps sending requests: nothing answers
# them until someone looks. Every minute this looks at each agent's session in
# herdr; one idle two checks running gets a nudge back to its loop, and again
# every five minutes while it stays idle. An agent whose node holds requests
# for a usage limit is left alone (it's right to stop), and so is one blocked
# on a question (that needs a person).
write_watchdog_unit() {
  mkdir -p "$UNITS"
  cat > "$UNITS/pantheon-watchdog.service" <<U
[Unit]
Description=Pantheon watchdog: nudges an agent whose session stopped working its inbox
[Service]
ExecStart=$here/scripts/host.sh watchdog-loop
Restart=on-failure
RestartSec=30
[Install]
WantedBy=default.target
U
}

cmd_watchdog() {
  command -v herdr >/dev/null || die "no herdr: the watchdog watches the agents' sessions in herdr"
  # --check: what it sees now, nudging no one
  if [ "${1:-}" = --check ]; then for a in $AGENTS; do dry=1 watch_agent "$a"; done; return 0; fi
  write_watchdog_unit; systemctl --user daemon-reload
  systemctl --user enable -q pantheon-watchdog.service; systemctl --user restart pantheon-watchdog.service
  say "watchdog started; its nudges: journalctl --user -u pantheon-watchdog"
}

# the pane of AGENT's tab "AGENT (vm)", in any workspace
vm_pane() {
  for w in $(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[].workspace_id'); do
    t=$(herdr tab list --workspace "$w" | jq -r --arg l "$1 (vm)" '.result.tabs[] | select(.label == $l) | .tab_id' | head -1)
    [ -n "$t" ] || continue
    herdr pane list --workspace "$w" | jq -r --arg t "$t" '.result.panes[] | select(.tab_id == $t) | .pane_id' | head -1
    return 0
  done
  return 1
}

watch_agent() {
  a=$1 st=$P/watchdog; mkdir -p "$st"
  if grep -q '^LIMIT' "$NET/$a/status.txt" 2>/dev/null; then rm -f "$st/$a"; return 0; fi
  if in_vm_agents "$a"; then
    # while Muse runs a command or thinks, its screen says "esc to interrupt"
    p=$(vm_pane "$a") || return 0
    if herdr pane read "$p" --source visible 2>/dev/null | grep -q "esc to interrupt"; then idle=0; else idle=1; fi
    file="~/pantheon/instructions.md"
  else
    case $(herdr agent list 2>/dev/null | jq -r --arg a "$a" '.result.agents[] | select(.name == $a) | .agent_status') in
      idle|done) idle=1 ;; *) idle=0 ;;   # working, blocked (a person's call), or no session
    esac
    file=$P/diplomats/$a.md
  fi
  [ -z "${dry:-}" ] || { say "watchdog: $a $([ "$idle" = 1 ] && echo idle || echo busy)"; return 0; }
  [ "$idle" = 1 ] || { rm -f "$st/$a"; return 0; }
  n=$(( $(cat "$st/$a" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$st/$a"
  [ "$n" -ge 2 ] && [ $(( (n - 2) % 5 )) -eq 0 ] || return 0
  msg="You stopped working your inbox, and your node keeps sending requests that nothing answers. Keep at it for as long as this session runs: wait, answer, repeat, and don't end your turn between requests (your instructions: $file). If your provider says you've hit a usage limit, report it with limited as they say, then stop. Start now."
  if in_vm_agents "$a"; then
    herdr pane send-text "$p" "$msg" >/dev/null && sleep 1 && herdr pane send-keys "$p" Enter >/dev/null
    # Muse sometimes keeps the text in its input after the first Enter
    sleep 3; herdr pane read "$p" | grep -q '^❯ You stopped working' && herdr pane send-keys "$p" Enter >/dev/null
  else
    herdr agent prompt "$a" "$msg" >/dev/null
  fi
  say "watchdog: $a's session had stopped (idle for $n checks): nudged it back to its inbox"
}

cmd_watchdog_loop() { while :; do for a in $AGENTS; do watch_agent "$a" || true; done; sleep 60; done; }

cmd_vm() {
  a=${1:-}; is_agent "$a" && in_vm_agents "$a" || die "usage: scripts/host.sh vm AGENT (one of VM_AGENTS: $VM_AGENTS)"
  command -v limactl >/dev/null || die "no limactl: install Lima (github.com/lima-vm/lima/releases: lima-VERSION-Linux-$(uname -m).tar.gz into ~/.local, bin/limactl on PATH)"
  command -v qemu-system-"$(uname -m)" >/dev/null || die "no qemu-system-$(uname -m): install qemu"
  v=$(vm "$a")
  limactl list -q 2>/dev/null | grep -qx "$v" || { say "making $v"; limactl create --tty=false --name="$v" "$here/deploy/host/agent-vm.yaml"; }
  [ "$(limactl list --format '{{.Status}}' "$v")" = Running ] || { say "starting $v"; limactl start --tty=false "$v"; }
  case $a in
    muse)
      # Muse's launcher fetches its runtime itself, once logged in
      m=$(command -v muse) || die "no muse on this host to copy its launcher from: install it here first"
      limactl copy "$m" "$v:/tmp/muse" && limactl shell "$v" sh -c 'mkdir -p ~/.local/bin && install -m 755 /tmp/muse ~/.local/bin/muse' ;;
  esac
  # Soma's source, to read (the VM has no GitHub access): not built
  if ! limactl shell "$v" test -f soma/GRADUAL.md 2>/dev/null; then
    say "copying Soma's source ($(soma_commit | cut -c1-10)) into $v"
    git -C "$SOMA" archive --format=tar HEAD | limactl shell "$v" sh -c 'mkdir -p ~/soma && tar -x -C ~/soma'
  fi
  limactl shell "$v" sh -c 'command -v git >/dev/null && command -v jq >/dev/null || { sudo apt-get update -q && sudo apt-get install -y -q git jq curl; }' >/dev/null
  # a token for this agent's inbox only; the instructions, the token beside them
  mkdir -p "$P/inbox/$a"
  [ -f "$P/inbox.json" ] || printf '{"listen": "127.0.0.1:%s", "url": "", "agents": {}}\n' "$PORT" > "$P/inbox.json"
  tmp=$(mktemp -d); umask 077
  # a token once; NEW_TOKEN=1 replaces it (a running session then loses its inbox)
  if [ -n "${NEW_TOKEN:-}" ] || ! limactl shell "$v" test -s pantheon/token 2>/dev/null; then
    python3 "$here/scripts/inbox-http.py" token "$P/inbox.json" "$a" "$P/inbox/$a" > "$tmp/token"; tok="a new token (the old one, if any, no longer works)"
  else tok="its token as it was"; fi
  { sed -e "s|{{AGENT}}|$a|g" -e "s|{{URL}}|http://$VM_HOST:$PORT|g" "$here/deploy/cloud/agent.md"
    printf '\nYour token is in the file ~/pantheon/token: send it as -H "Authorization: Bearer $(cat ~/pantheon/token)". This VM is your machine: work in it as you like.\n'
    printf '\n## Soma, the language Pantheon is written in\n\nSoma is a fork of the Rocq Prover with gradual dependent types, and its source is its documentation: ~/soma is the commit the network builds with (%s; not built here). Start with README.md, GRADUAL.md, gradual-coverage.md, vision.md and examples/; test-suite/ and theories/ show how a feature behaves. When a task leans on a Soma feature, look it up there instead of guessing from Rocq you remember: this fork differs. This network changes Pantheon only; if you find a Soma bug or gap, say so in your patch note or reason, starting with "soma:".\n' "$(soma_commit)"; } > "$tmp/instructions.md"
  limactl shell "$v" sh -c 'mkdir -p ~/pantheon && chmod 700 ~/pantheon'
  case $a in
    muse) printf '#!/bin/sh\ncd ~/pantheon && exec ~/.local/bin/muse --yolo "Read ~/pantheon/instructions.md: it is your job. Follow it now."\n' > "$tmp/start.sh" ;;
  esac
  limactl copy "$tmp"/* "$v:pantheon/"; rm -rf "$tmp"
  case $tok in "a new"*) systemctl --user try-restart pantheon-inbox.service 2>/dev/null || true ;; esac
  say "$v is up, with $a's CLI, Soma's source, instructions and $tok"
  say "next: scripts/host.sh login $a (once), then scripts/host.sh diplomats"
}

cmd_login() {
  a=${1:-}; in_vm_agents "$a" || die "usage: scripts/host.sh login AGENT (one of VM_AGENTS: $VM_AGENTS; the others log in on this host: claude, codex, cursor-agent login)"
  case $a in muse) exec limactl shell "$(vm "$a")" sh -c 'exec ~/.local/bin/muse login' ;; esac
}

# start: AGENT KIND EXECUTABLE ARGS..., in a herdr tab of its own
cmd_diplomats() {
  command -v herdr >/dev/null || die "no herdr: install it (herdr.dev)"
  [ "${HERDR_ENV:-}" = 1 ] || die "run this from a pane in herdr (start herdr on this host, then run it there)"
  [ -d "$NET" ] || die "no network yet: scripts/host.sh network, then start"
  # tabs in the workspace this runs from
  ws=${HERDR_WORKSPACE_ID:?run this from a pane in herdr}
  root=$(herdr tab create --workspace "$ws" --label status --cwd "$P" --no-focus | jq -r .result.root_pane.pane_id)
  herdr pane run "$root" "while :; do clear; $here/scripts/host.sh status; sleep 20; done" >/dev/null
  for a in $AGENTS; do
    if in_vm_agents "$a"; then
      p=$(herdr tab create --workspace "$ws" --label "$a (vm)" --cwd "$P" --no-focus | jq -r .result.root_pane.pane_id)
      case $a in
        muse) herdr pane run "$p" "$(command -v limactl) shell --workdir / $(vm "$a") sh -c 'exec sh \"\$HOME/pantheon/start.sh\"'" >/dev/null ;;
      esac
      say "$a: in its VM, tab \"$a (vm)\""; continue
    fi
    case $a in
      claude) kind=claude exe=claude args="--dangerously-skip-permissions" ;;
      codex)  kind=codex exe=codex args="--dangerously-bypass-approvals-and-sandbox" ;;
      grok)   kind=cursor exe=cursor-agent args="--yolo --trust --model $GROK_MODEL" ;;
      *) say "$a: no diplomat for it here"; continue ;;
    esac
    command -v "$exe" >/dev/null || { say "$a: no $exe on this host: install it and log it in, then run this again"; continue; }
    render_diplomat "$a"
    p=$(herdr tab create --workspace "$ws" --label "$a" --cwd "$P/desk/$a" --no-focus \
      --env "PANTHEON_INBOX=$P/inbox/$a" --env "PANTHEON_REMOTE=$REMOTE" --env "PANTHEON_BRANCH=$BRANCH" \
      --env "PANTHEON_CHECK=$here/scripts/host.sh check" --env "PATH=$here/scripts:$PATH" | jq -r .result.root_pane.pane_id)
    # shellcheck disable=SC2086
    herdr agent start "$a" --kind "$kind" --pane "$p" --timeout 60000 -- $args >/dev/null \
      || { say "$a: $exe didn't come up ready (logged in? herdr pane read $p)"; continue; }
    herdr agent prompt "$a" "Read $P/diplomats/$a.md: it is your job, as $a's diplomat in a Pantheon network. Follow it now." >/dev/null
    say "$a: started in tab \"$a\""
  done
  say "in this workspace ($ws): a tab per agent, and one for status"
}

cmd_instructions() {
  for a in $AGENTS; do in_vm_agents "$a" || { render_diplomat "$a"; say "$a: $P/diplomats/$a.md"; }; done
  [ -z "$VM_AGENTS" ] || say "the VMs' instructions: scripts/host.sh vm AGENT"
}

cmd_check() {
  d=${1:-}; [ -d "$d" ] || die "usage: scripts/host.sh check DIR (a checkout of Pantheon)"
  SOMA_DIR=$SOMA exec "$here/deploy/host/ci-sandbox" "$CI_MEMORY" "$d" "$CI_CMD"
}

cmd_stop() { systemctl --user stop pantheon-watchdog.service pantheon-mirror.service pantheon-inbox.service $(for a in $AGENTS; do printf 'pantheon-node@%s ' "$a"; done) 2>/dev/null; say "stopped"; }

cmd_status() {
  for a in $AGENTS; do
    printf '== %s (%s)\n' "$a" "$(systemctl --user is-active "pantheon-node@$a" 2>/dev/null || true)"
    sed -n '1,3p' "$NET/$a/status.txt" 2>/dev/null | sed 's/^/   /'
    grep -h '^LIMIT' "$NET/$a/status.txt" 2>/dev/null | sed 's/^/   /' || true
    n=$(ls "$P/inbox/$a" 2>/dev/null | grep -c '^[0-9]*-' || true); [ "$n" = 0 ] || printf '   inbox: %s waiting\n' "$n"
  done
  printf '== tasks and bids (claude'"'"'s view)\n'; grep -E '^(task|bid) ' "$NET/claude/status.txt" 2>/dev/null | cut -c1-160 | tail -12 | sed 's/^/   /' || true
  printf '== services: mirror %s, inbox %s, watchdog %s; VMs: %s\n' "$(systemctl --user is-active pantheon-mirror 2>/dev/null || true)" \
    "$(systemctl --user is-active pantheon-inbox 2>/dev/null || true)" "$(systemctl --user is-active pantheon-watchdog 2>/dev/null || true)" \
    "$(for a in $VM_AGENTS; do printf '%s %s ' "$(vm "$a")" "$(limactl list --format '{{.Status}}' "$(vm "$a")" 2>/dev/null || echo none)"; done)"
  journalctl --user -u pantheon-mirror -n 1 -o cat 2>/dev/null | grep -q 'mirror:' && printf '   %s\n' "$(journalctl --user -u pantheon-mirror -n 1 -o cat | cut -c1-200)"
  printf '== memory: %s\n' "$(free -m | awk '/^Mem/ {print $7 " MB available of " $2}')"
}

cmd_logs() {
  case ${1:-} in
    '') exec journalctl --user -f -u pantheon-mirror -u pantheon-inbox ;;
    *) exec journalctl --user -f -u "pantheon-node@$1" ;;
  esac
}

c=${1:-}; [ $# -gt 0 ] && shift
case $c in
  network|start|vm|login|diplomats|watchdog|instructions|mirror|check|stop|status|logs) "cmd_$c" "$@" ;;
  mirror-loop) cmd_mirror_loop ;;
  watchdog-loop) cmd_watchdog_loop ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; [ -z "$c" ] || exit 1 ;;
esac
