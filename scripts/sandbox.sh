#!/bin/sh
# A Pantheon network on this Mac, one VM per agent: what docs/NETWORK.md does
# with four machines, with each machine a Lima VM (Apple's Virtualization
# framework). The VMs share nothing of the Mac: no mounts, no forwarded ports,
# no route to its localhost or your LAN. Inside each, the node and the model
# run as different users, and CI runs in Docker with no network. See
# docs/SANDBOX.md.
#
#   scripts/sandbox.sh base                  build the VM every node is cloned from (once, ~20 min)
#   scripts/sandbox.sh nodes                 one VM per agent, cloned from it
#   scripts/sandbox.sh network               the node built from PANTHEON_COMMIT, keys, the network directory, genesis
#   scripts/sandbox.sh update                rebuild every VM's node from PANTHEON_COMMIT (network does this)
#   scripts/sandbox.sh login AGENT           the model's login inside AGENT's VM
#   scripts/sandbox.sh session AGENT         an interactive session for an agent on the inbox backend (muse)
#   scripts/sandbox.sh start [AGENT=BACKEND ...] [-- NODE FLAGS]
#   scripts/sandbox.sh status | logs AGENT | fetch | stop | shell AGENT
#   scripts/sandbox.sh reset                 discard the chain: every node's home and the network directory
#
# Settings, from the environment:
#   AGENTS           the four agents (default: claude codex grok muse)
#   SOMA_CHECKOUT    Soma's checkout (default: ../soma next to this one)
#   SOMA_COMMIT      Soma's commit to start from (default: the checkout's gradual)
#   PANTHEON_COMMIT  Pantheon's commit to start from (default: HEAD)
#   SANDBOX_DIR      where the network directory is kept on the Mac (default: ~/.pantheon-sandbox)
#   VM_MEMORY        GiB per VM (default 6), VM_CPUS (default 4)
#   CI_MEMORY        a CI container's memory and /tmp (default 6g)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
AGENTS=${AGENTS:-claude codex grok muse}
SOMA_CHECKOUT=${SOMA_CHECKOUT:-$(cd "$here/.." && pwd)/soma}
SANDBOX_DIR=${SANDBOX_DIR:-$HOME/.pantheon-sandbox}
VM_MEMORY=${VM_MEMORY:-6} VM_CPUS=${VM_CPUS:-4} CI_MEMORY=${CI_MEMORY:-6g}
BASE=pantheon-base
HOMEDIR=/var/lib/pantheon/home
NODE=/home/pantheon/pantheon/main.exe

say() { printf 'sandbox: %s\n' "$*"; }
die() { printf 'sandbox: %s\n' "$*" >&2; exit 1; }
vm() { printf 'pantheon-%s' "$1"; }
exists() { limactl list -q 2>/dev/null | grep -qx "$1"; }
running() { [ "$(limactl list --format '{{.Status}}' "$1" 2>/dev/null)" = Running ]; }
in_vm() { v=$1; shift; limactl shell --workdir / "$v" "$@"; }
as_node() { v=$1; shift; in_vm "$v" sudo -u pantheon -H "$@"; }
need() { command -v "$1" >/dev/null || die "$1 is not installed. $2"; }
need limactl "Install it with: brew install lima"
limactl() { command limactl --log-level=warn "$@"; }

cmd_base() {
  [ -d "$SOMA_CHECKOUT/.git" ] || die "no Soma checkout at $SOMA_CHECKOUT: set SOMA_CHECKOUT"
  if ! exists $BASE; then
    say "creating $BASE"
    limactl create --name=$BASE --tty=false --memory="$VM_MEMORY" --cpus="$VM_CPUS" "$here/deploy/sandbox/lima.yaml" >/dev/null
  fi
  running $BASE || limactl start --tty=false $BASE >/dev/null
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  git -C "$here" archive --format=tar "${PANTHEON_COMMIT:-HEAD}" > "$tmp/pantheon.tar"
  git -C "$SOMA_CHECKOUT" archive --format=tar "${SOMA_COMMIT:-gradual}" > "$tmp/soma.tar"
  cp "$here/deploy/sandbox/provision.sh" "$here/deploy/sandbox/firewall.nft" "$here/deploy/sandbox/pantheon-docker" "$tmp/"
  in_vm $BASE sh -c 'rm -rf /tmp/prov && mkdir /tmp/prov'
  limactl copy -r "$tmp/." $BASE:/tmp/prov/
  say "provisioning $BASE: packages, users, firewall, then Soma and Pantheon from source (the first time, ~20 min)"
  in_vm $BASE sudo sh /tmp/prov/provision.sh
  if ! in_vm $BASE sudo docker image inspect pantheon:dev >/dev/null 2>&1; then
    if command -v docker >/dev/null && docker image inspect pantheon:dev >/dev/null 2>&1; then
      say "copying the CI image pantheon:dev from this Mac's Docker"
      docker save pantheon:dev | in_vm $BASE sudo docker load
    else
      say "building the CI image pantheon:dev inside $BASE (a while)"
      in_vm $BASE sudo sh -c 'rm -rf /tmp/ci && mkdir -p /tmp/ci/pantheon /tmp/ci/soma && tar -x -C /tmp/ci/pantheon -f /tmp/prov/pantheon.tar && tar -x -C /tmp/ci/soma -f /tmp/prov/soma.tar && docker build -q -f /tmp/ci/pantheon/deploy/Dockerfile --build-context soma=/tmp/ci/soma -t pantheon:dev /tmp/ci/pantheon && rm -rf /tmp/ci'
    fi
  fi
  in_vm $BASE sudo rm -rf /tmp/prov
  limactl stop $BASE >/dev/null
  say "$BASE is ready. Next: scripts/sandbox.sh nodes"
}

cmd_nodes() {
  exists $BASE || die "no $BASE yet: run scripts/sandbox.sh base first"
  running $BASE && limactl stop $BASE >/dev/null
  for a in $AGENTS; do
    v=$(vm "$a")
    if ! exists "$v"; then say "cloning $v"; limactl clone --tty=false $BASE "$v" >/dev/null; fi
    running "$v" || limactl start --tty=false "$v" >/dev/null
    in_vm "$v" sudo hostnamectl set-hostname "$v"
    say "$v: $(in_vm "$v" sh -c "ip -4 -o addr show eth0 | awk '{print \$4}'")"
  done
  say "next: scripts/sandbox.sh network"
}

# Every VM's node, built from the commit the chain starts from, as each agent
# would on its own machine: soma build, from source
cmd_update() {
  commit=$(git -C "$here" rev-parse "${PANTHEON_COMMIT:-HEAD}")
  for a in $AGENTS; do
    v=$(vm "$a"); running "$v" || die "$v isn't running: scripts/sandbox.sh nodes"
    [ "$(in_vm "$v" sudo cat /home/pantheon/pantheon/.commit 2>/dev/null)" = "$commit" ] && continue
    git -C "$here" archive --format=tar "$commit" | in_vm "$v" sudo -u pantheon -H sh -c \
      'cd ~/pantheon && find . -mindepth 1 -maxdepth 1 ! -name .soma-cache -exec rm -rf {} + && tar -x -f - && soma build main.soma >/tmp/pantheon-build.log 2>&1' \
      || die "building Pantheon $commit failed on $v: scripts/sandbox.sh shell $a, then: sudo cat /tmp/pantheon-build.log"
    printf '%s\n' "$commit" | in_vm "$v" sudo -u pantheon sh -c 'cat > ~/pantheon/.commit; chmod -R a+rX ~/pantheon'
    say "$a: node built from $(git -C "$here" log -1 --format='%h %s' "$commit")"
  done
}

cmd_network() {
  cmd_update
  net=$SANDBOX_DIR/network
  mkdir -p "$net/parts" "$net/repos"
  for a in $AGENTS; do
    v=$(vm "$a"); running "$v" || die "$v isn't running: scripts/sandbox.sh nodes"
    in_vm "$v" sudo test -f $HOMEDIR/key.json || as_node "$v" $NODE keygen $HOMEDIR --name "$a" --addr "lima-$v.internal:26700" >/dev/null
    in_vm "$v" sudo cat $HOMEDIR/public.json > "$net/parts/$a.json"
  done
  soma_commit=$(git -C "$SOMA_CHECKOUT" rev-parse "${SOMA_COMMIT:-gradual}")
  pantheon_commit=$(git -C "$here" rev-parse "${PANTHEON_COMMIT:-HEAD}")
  # both repositories up to their genesis commits, which the VMs clone
  for r in soma:$SOMA_CHECKOUT:$soma_commit pantheon:$here:$pantheon_commit; do
    name=${r%%:*} rest=${r#*:}; src=${rest%%:*} commit=${rest#*:}
    rm -rf "$net/repos/$name.git"
    git init -q --bare "$net/repos/$name.git"
    git -C "$src" push -q "$net/repos/$name.git" "$commit:refs/heads/genesis"
    git -C "$net/repos/$name.git" symbolic-ref HEAD refs/heads/genesis
  done
  if [ ! -f "$net/network.json" ]; then
    jq --arg s "$soma_commit" --arg p "$pantheon_commit" \
      '.repos = [{name: "pantheon", url: "repos/pantheon.git", commit: $p}, {name: "soma", url: "repos/soma.git", commit: $s}]' \
      "$here/examples/network/network.json" > "$net/network.json"
  fi
  hashes=""
  for a in $AGENTS; do
    v=$(vm "$a")
    in_vm "$v" sudo rm -rf /var/lib/pantheon/network
    tar -C "$SANDBOX_DIR" -cf - network | in_vm "$v" sudo tar -x -C /var/lib/pantheon -f -
    in_vm "$v" sudo chown -R pantheon:pantheon /var/lib/pantheon/network
    h=$(as_node "$v" $NODE genesis $HOMEDIR /var/lib/pantheon/network 2>&1 | grep -o 'genesis hash [0-9a-f]*' | awk '{print $3}')
    [ -n "$h" ] || die "genesis failed on $v: run scripts/sandbox.sh shell $a, then: sudo -u pantheon $NODE genesis $HOMEDIR /var/lib/pantheon/network"
    say "$a: genesis $h"; hashes="$hashes $h"
  done
  [ "$(echo $hashes | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')" = 1 ] || die "the genesis hashes differ: don't start until they match"
  say "every agent has the same genesis. Next: scripts/sandbox.sh login AGENT for each model, then scripts/sandbox.sh start"
}

# Grok Build and the Cursor CLI, by their vendors' installers, for the bidder
install_grok() {
  say "installing Grok Build (x.ai/cli) and the Cursor CLI (cursor.com/install) in $1"
  in_vm "$1" sudo -u bidder -H sh -c 'curl -fsSL https://x.ai/cli/install.sh | bash && curl -fsS https://cursor.com/install | bash' >/dev/null
  in_vm "$1" sudo sh -c 'for c in grok:/home/bidder/.grok/bin/grok cursor-agent:/home/bidder/.local/bin/cursor-agent; do
      printf "#!/bin/sh\n. /usr/local/lib/pantheon/model-env\nexec %s \"\$@\"\n" "${c#*:}" > "/usr/local/bin/${c%%:*}"; chmod 755 "/usr/local/bin/${c%%:*}"; done'
  in_vm "$1" sudo -u bidder -H grok --version || die "Grok Build didn't install in $1"
}

install_muse() {
  in_vm "$1" sudo sh -c 'install -d -o bidder -g bidder /home/bidder/.local /home/bidder/.local/bin
    sudo -u bidder -H sh -c "curl -fsSL https://api.meta.ai/muse-launcher.sh -o ~/.local/bin/muse && chmod +x ~/.local/bin/muse"
    printf "#!/bin/sh\n. /usr/local/lib/pantheon/model-env\nexec /home/bidder/.local/bin/muse \"\$@\"\n" > /usr/local/bin/muse && chmod 755 /usr/local/bin/muse'
}

# The model's login lives with the VM's bidder user, which runs the model:
# its subscription, by the CLI's own login for machines without a browser
# (a URL or a device code you approve). With --api-key, the API key in the
# environment instead, billed to the API.
cmd_login() {
  a=${1:?usage: scripts/sandbox.sh login AGENT [--api-key]}; v=$(vm "$a"); running "$v" || die "$v isn't running"
  key=false; [ "${2:-}" = --api-key ] && key=true
  envf=/home/bidder/.config/pantheon/model.env
  put() { printf '%s\n' "$1" | in_vm "$v" sudo -u bidder sh -c "umask 077; cat > $envf"; }
  as_bidder() { in_vm "$v" sudo -u bidder -H "$@"; }
  [ -t 0 ] || $key || die "a subscription login is interactive: run it in a terminal (or use --api-key)"
  put ""   # an API key in model.env would take precedence over the subscription
  case $a in
    claude)
      if $key; then put "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"
      else say "log in with your Claude subscription: open the URL, then paste the code back here"; as_bidder claude auth login --claudeai
      fi
      as_bidder claude auth status ;;
    codex)
      if $key; then printf '%s\n' "${OPENAI_API_KEY:?set OPENAI_API_KEY}" | as_bidder codex login --with-api-key
      else say "log in with your ChatGPT subscription: open the URL and enter the code"; as_bidder codex login --device-auth
      fi
      as_bidder codex login status ;;
    grok)
      in_vm "$v" test -x /usr/local/bin/grok || install_grok "$v"
      GROK_BUILD_MODEL=${GROK_BUILD_MODEL:-grok-build-0.1}
      printf '%s\n' "GROK_BUILD_MODEL=$GROK_BUILD_MODEL" | in_vm "$v" sudo sh -c 'umask 077; cat > /etc/pantheon/keys.env'
      if $key; then
        put "$(printf 'XAI_API_KEY=%s\n%s' "${XAI_API_KEY:?set XAI_API_KEY}" "${CURSOR_API_KEY:+CURSOR_API_KEY=$CURSOR_API_KEY}")"
        printf 'XAI_API_KEY=%s\n' "$XAI_API_KEY" | in_vm "$v" sudo sh -c 'cat >> /etc/pantheon/keys.env'
      else
        say "log in with your Grok subscription: open the URL and enter the code"
        as_bidder grok login --device-auth
        say "and the Cursor CLI with your Cursor subscription: open the URL"
        as_bidder env NO_OPEN_BROWSER=1 cursor-agent login || say "the Cursor CLI isn't logged in: Grok Build bids without it. Run login grok again to retry"
      fi
      as_bidder grok models 2>&1 | head -3 ;;
    muse)
      in_vm "$v" test -x /usr/local/bin/muse || install_muse "$v"
      if $key; then put "META_API_KEY=${META_API_KEY:?set META_API_KEY}"
      else say "log in with your Meta account: open the URL and approve the code"; as_bidder muse login
      fi
      as_bidder muse usage 2>&1 | head -3 || true ;;
    *) die "no login for $a: give it a cmd: backend whose program has its own login (see docs/SANDBOX.md)" ;;
  esac
  say "$a: logged in"
}

default_backend() {
  case $1 in
    claude) echo cmd:/usr/local/lib/pantheon/bidder-claude.sh ;;
    codex) echo cmd:/usr/local/lib/pantheon/bidder-codex.sh ;;
    grok) echo cmd:/usr/local/lib/pantheon/bidder-grok.sh ;;
    muse) echo cmd:/usr/local/lib/pantheon/bidder-inbox.sh ;;
    *) echo scripted ;;
  esac
}

# The inbox: requests from the node to an agent working in a session of its
# own (scripts/bidder-inbox.sh, scripts/pantheon-inbox). Both users write it.
setup_inbox() {
  v=$1
  # the bidders, from this checkout, so a VM never runs a stale copy
  for f in bidder.sh bidder-claude.sh bidder-codex.sh bidder-grok.sh; do
    in_vm "$v" sudo sh -c "cat > /usr/local/lib/pantheon/$f && chmod 755 /usr/local/lib/pantheon/$f" < "$here/scripts/$f"
  done
  in_vm "$v" sudo sh -c 'cat > /usr/local/lib/pantheon/bidder-inbox.sh && chmod 755 /usr/local/lib/pantheon/bidder-inbox.sh' < "$here/scripts/bidder-inbox.sh"
  in_vm "$v" sudo sh -c 'cat > /usr/local/bin/pantheon-inbox && chmod 755 /usr/local/bin/pantheon-inbox' < "$here/scripts/pantheon-inbox"
  in_vm "$v" sudo sh -c 'getent group inbox >/dev/null || groupadd inbox; usermod -aG inbox pantheon; usermod -aG inbox bidder; install -d -o pantheon -g inbox -m 2770 /var/lib/pantheon-inbox'
}

session_cmd() {
  case $1 in
    muse) echo 'muse --yolo' ;;
    claude) echo 'claude --dangerously-skip-permissions' ;;
    codex) echo 'codex --dangerously-bypass-approvals-and-sandbox' ;;
    *) die "no interactive CLI known for $1: set SESSION_CMD" ;;
  esac
}

# An interactive session for an agent whose node uses the inbox backend: the
# model's own CLI, as the bidder user, with full permissions (the VM is the
# sandbox), told how to work the inbox (deploy/sandbox/session.md). It runs
# in this terminal; while it's closed, the node's requests time out.
cmd_session() {
  a=${1:?usage: scripts/sandbox.sh session AGENT}; v=$(vm "$a"); running "$v" || die "$v isn't running"
  c=${SESSION_CMD:-$(session_cmd "$a")}
  setup_inbox "$v"
  sed "s/^You are AGENT,/You are $a,/" "$here/deploy/sandbox/session.md" | in_vm "$v" sudo sh -c 'cat > /etc/pantheon/session.md'
  [ -t 0 ] || die "session is interactive: run it in a terminal"
  command limactl --log-level=warn shell --workdir / "$v" sudo -u bidder -H sh -c "cd ~ && exec $c \"\$(cat /etc/pantheon/session.md)\""
}

cmd_start() {
  overrides="" flags=""
  while [ $# -gt 0 ]; do
    case $1 in --) shift; flags="$*"; break ;; *=*) overrides="$overrides $1" ;; *) die "start takes AGENT=BACKEND, then -- and node flags" ;; esac
    shift
  done
  for a in $AGENTS; do
    v=$(vm "$a"); running "$v" || die "$v isn't running"
    b=$(default_backend "$a")
    for o in $overrides; do [ "${o%%=*}" = "$a" ] && b=${o#*=}; done
    # what node.sh reads: see deploy/sandbox/node.sh
    put() { in_vm "$v" sudo sh -c "cat > /etc/pantheon/$1"; }
    in_vm "$v" sudo mkdir -p /etc/pantheon/ci
    put node.sh < "$here/deploy/sandbox/node.sh"
    printf '%s\n' "$b" | put backend
    printf '%s\n' "$CI_MEMORY" | put ci-memory
    printf '%s\n' "${PANTHEON_CI:-soma build main.soma && test/edits.sh}" | put ci/pantheon
    printf '%s\n' "${SOMA_CI:-eval \"\$(opam env --switch=soma-build --set-switch)\" && make dunestrap >/dev/null && dune build -j 2 soma-runtime.install soma-core.install}" | put ci/soma
    printf '%s\n' --bid-window 900 --max-llm-calls 200 $flags | put flags
    put goal.txt < "${GOAL_FILE:-$here/examples/dogfood/goal.txt}"
    setup_inbox "$v"
    printf '[Service]\nSyslogIdentifier=pantheon\n' | in_vm "$v" sudo sh -c 'mkdir -p /etc/systemd/system/pantheon-node.service.d && cat > /etc/systemd/system/pantheon-node.service.d/log.conf && systemctl daemon-reload'
    in_vm "$v" sudo systemctl enable -q pantheon-node
    in_vm "$v" sudo systemctl restart pantheon-node
    say "$a: started, backend $b"
  done
  say "watch it with: scripts/sandbox.sh status"
}

cmd_status() {
  for a in $AGENTS; do
    v=$(vm "$a")
    printf '== %s (%s)\n' "$a" "$(running "$v" && in_vm "$v" systemctl is-active pantheon-node 2>/dev/null || echo 'VM stopped')"
    running "$v" && as_node "$v" $NODE status $HOMEDIR 2>&1 | sed 's/^/   /' || true
  done
}

cmd_logs() { a=${1:?usage: scripts/sandbox.sh logs AGENT [LINES]}; in_vm "$(vm "$a")" sudo journalctl -u pantheon-node -t pantheon --no-pager -o cat -n "${2:-60}"; }
cmd_shell() { a=${1:?usage: scripts/sandbox.sh shell AGENT}; limactl shell "$(vm "$a")"; }
cmd_stop() { for a in $AGENTS; do v=$(vm "$a"); running "$v" && { in_vm "$v" sudo systemctl stop pantheon-node; limactl stop "$v" >/dev/null; say "$v stopped"; }; done; true; }

# A new chain needs new homes, as on real machines: this discards every
# node's keys, blocks and checkouts, and the network directory. The VMs stay.
cmd_reset() {
  for a in $AGENTS; do
    v=$(vm "$a"); running "$v" || continue
    in_vm "$v" sudo systemctl stop pantheon-node
    in_vm "$v" sudo rm -rf $HOMEDIR /var/lib/pantheon/network
  done
  rm -rf "$SANDBOX_DIR/network"
  say "the chain is gone. Next: scripts/sandbox.sh network"
}

# Each governed repository's head on one node, as the branch pantheon/merged
# of your checkout. Fast-forward only, like scripts/mirror.sh.
cmd_fetch() {
  a=${1:-$(echo $AGENTS | cut -d' ' -f1)}; v=$(vm "$a")
  export GIT_SSH_COMMAND="ssh -F $HOME/.lima/$v/ssh.config"
  for r in pantheon:$here soma:$SOMA_CHECKOUT; do
    name=${r%%:*} dst=${r#*:}
    git -C "$dst" fetch -q --upload-pack "sudo -u pantheon git-upload-pack" "lima-$v:$HOMEDIR/repos/$name" "HEAD:refs/heads/pantheon/merged" \
      && say "$name: pantheon/merged is $(git -C "$dst" log -1 --format='%h %s' pantheon/merged)" \
      || say "$name: couldn't fast-forward pantheon/merged from $a (see above)"
  done
}

c=${1:-}; [ $# -gt 0 ] && shift
case $c in
  base|nodes|network|update|login|session|start|status|logs|shell|stop|fetch|reset) "cmd_$c" "$@" ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; [ -z "$c" ] || exit 1 ;;
esac
