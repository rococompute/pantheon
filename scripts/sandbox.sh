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
#   scripts/sandbox.sh forwards              under JOIN: (re)start the forwards to the VMs' nodes
#   scripts/sandbox.sh reset                 discard the chain: every node's home and the network directory
#   scripts/sandbox.sh epoch                 a new epoch: every VM's Soma and CI image from SOMA_COMMIT, its node
#                                            from PANTHEON_COMMIT, and a new chain from both; logins stay
#
# Settings, from the environment:
#   AGENTS           the four agents (default: claude codex grok muse)
#   SOMA_CHECKOUT    Soma's checkout (default: ../soma next to this one)
#   SOMA_COMMIT      Soma's commit to start from (default: the checkout's gradual)
#   PANTHEON_COMMIT  Pantheon's commit to start from (default: HEAD)
#   SANDBOX_DIR      where the network directory is kept on the Mac (default: ~/.pantheon-sandbox)
#   VM_MEMORY        GiB per VM (default 4), VM_CPUS (default 4); nodes applies a change
#   CI_MEMORY        a CI container's memory and /tmp (default 3g: Soma's build peaks at 2.3)
#   SOMA_CI_AGENTS   the agents that run Soma's CI (default: claude codex grok; see docs/SANDBOX.md)
#   REPOS            the repositories genesis governs (default: pantheon soma). REPOS=pantheon
#                    runs a market on Pantheon alone: no Soma tasks, so no Soma CI builds
#   JOIN             another host's agents in the same network, by scripts/host.sh there: USER@HOST,
#                    reached with tailscale ssh (default: none). The VMs' nodes then take addresses on
#                    this Mac's tailnet address, ports 26701 on, forwarded to them (scripts/sandbox.sh forwards)
#   JOIN_AGENTS      its agents (default: claude codex grok muse, each with -HOST after it)
#   JOIN_DIR         its Pantheon checkout, under its home (default: pantheon/pantheon)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
AGENTS=${AGENTS:-claude codex grok muse}
SOMA_CHECKOUT=${SOMA_CHECKOUT:-$(cd "$here/.." && pwd)/soma}
SANDBOX_DIR=${SANDBOX_DIR:-$HOME/.pantheon-sandbox}
VM_MEMORY=${VM_MEMORY:-4} VM_CPUS=${VM_CPUS:-4} CI_MEMORY=${CI_MEMORY:-3g}
SOMA_CI_AGENTS=${SOMA_CI_AGENTS:-claude codex grok}
REPOS=${REPOS:-pantheon soma}
for r in $REPOS; do case $r in pantheon|soma) ;; *) printf 'sandbox: REPOS has %s: it can name pantheon and soma\n' "$r" >&2; exit 1 ;; esac; done
JOIN=${JOIN:-}
JOIN_AGENTS=${JOIN_AGENTS:-$( [ -z "$JOIN" ] || for k in claude codex grok muse; do printf '%s-%s ' "$k" "${JOIN#*@}"; done)}
JOIN_DIR=${JOIN_DIR:-pantheon/pantheon}
BASE=pantheon-base
HOMEDIR=/var/lib/pantheon/home
NODE=/home/pantheon/pantheon/main.exe

say() { printf 'sandbox: %s\n' "$*"; }
die() { printf 'sandbox: %s\n' "$*" >&2; exit 1; }
vm() { printf 'pantheon-%s' "$1"; }
# a governed repository's checkout on this Mac
repo_src() { case $1 in pantheon) echo "$here" ;; soma) echo "$SOMA_CHECKOUT" ;; esac; }
governs() { case " $REPOS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
exists() { limactl list -q 2>/dev/null | grep -qx "$1"; }
running() { [ "$(limactl list --format '{{.Status}}' "$1" 2>/dev/null)" = Running ]; }
in_vm() { v=$1; shift; limactl shell --workdir / "$v" "$@"; }
as_node() { v=$1; shift; in_vm "$v" sudo -u pantheon -H "$@"; }
need() { command -v "$1" >/dev/null || die "$1 is not installed. $2"; }
need limactl "Install it with: brew install lima"
limactl() { command limactl --log-level=warn "$@"; }

# JOIN: the other host, by tailscale ssh; its scripts/host.sh with its agents
# and its tailnet address (stdin goes through only for remote_in)
tailnet_ip() { tailscale ip -4 2>/dev/null | head -1; }
join_ip() { tailscale ip -4 "${JOIN#*@}" 2>/dev/null | head -1; }
remote() { tailscale ssh "$JOIN" "$@" </dev/null; }
remote_in() { tailscale ssh "$JOIN" "$@"; }
host_sh() { printf 'cd ~/%s && AGENTS=%s LISTEN=%s scripts/host.sh' "$JOIN_DIR" "'$JOIN_AGENTS'" "$(join_ip)"; }
# a VM agent's port under JOIN: 26701 for the first, and on
agent_port() { i=26701; for x in $AGENTS; do [ "$x" = "$1" ] && { echo $i; return; }; i=$((i + 1)); done; }
vm_ip() { in_vm "$(vm "$1")" sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1"; }

# Under JOIN each VM's node is reached at this Mac's tailnet address: an ssh
# forward per VM, on the tailnet address only (not the LAN), and a firewall
# rule in the VM letting its node reach this Mac and the other host there
cmd_forwards() {
  [ -n "$JOIN" ] || die "forwards are for JOIN: set JOIN=USER@HOST"
  t=$(tailnet_ip); j=$(join_ip); [ -n "$t" ] && [ -n "$j" ] || die "no tailnet address for this Mac or ${JOIN#*@}: is tailscale up?"
  for a in $AGENTS; do
    v=$(vm "$a"); p=$(agent_port "$a"); ip=$(vm_ip "$a")
    pkill -f -- "-L $t:$p:" 2>/dev/null || true
    ssh -F "$HOME/.lima/$v/ssh.config" -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L "$t:$p:$ip:$p" "lima-$v" \
      || die "$a: can't forward $t:$p to $v"
    uid=$(in_vm "$v" id -u pantheon)
    in_vm "$v" sudo sh -c "nft -a list chain inet pantheon out | sed -n 's/.*comment \"join\".*# handle \([0-9]*\)\$/\1/p' | while read h; do nft delete rule inet pantheon out handle \$h; done
      nft insert rule inet pantheon out meta skuid $uid ip daddr '{ $t, $j }' tcp dport 26701-26799 accept comment '\"join\"'"
    say "$a: $t:$p forwarded to $v ($ip:$p)"
  done
}

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
  cp "$here/deploy/sandbox/provision.sh" "$here/deploy/sandbox/firewall.nft" "$here/deploy/sandbox/pantheon-docker" "$here/deploy/sandbox/model-env" "$tmp/"
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
    mem=$(limactl list --format '{{.Memory}}' "$v")
    if [ "$mem" != $((VM_MEMORY * 1024 * 1024 * 1024)) ]; then
      say "$v: memory to ${VM_MEMORY} GiB"
      running "$v" && limactl stop "$v" >/dev/null
      limactl edit --tty=false --memory "$VM_MEMORY" --cpus "$VM_CPUS" "$v" >/dev/null
    fi
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
  for a in $AGENTS; do running "$(vm "$a")" && in_vm "$(vm "$a")" sudo systemctl disable -q --now pantheon-node; done
  cmd_update
  net=$SANDBOX_DIR/network
  mkdir -p "$net/parts" "$net/repos"
  for a in $AGENTS; do
    v=$(vm "$a"); running "$v" || die "$v isn't running: scripts/sandbox.sh nodes"
    if [ -n "$JOIN" ]; then addr="$(tailnet_ip):$(agent_port "$a")"; else addr="lima-$v.internal:26700"; fi
    in_vm "$v" sudo test -f $HOMEDIR/key.json || as_node "$v" $NODE keygen $HOMEDIR --name "$a" --addr "$addr" >/dev/null
    in_vm "$v" sudo cat $HOMEDIR/public.json > "$net/parts/$a.json"
  done
  soma_commit=$(git -C "$SOMA_CHECKOUT" rev-parse "${SOMA_COMMIT:-gradual}")
  pantheon_commit=$(git -C "$here" rev-parse "${PANTHEON_COMMIT:-HEAD}")
  if [ -n "$JOIN" ]; then
    # the other host: its node built from the same commit (from GitHub), its
    # last chain moved aside, and its agents' public parts
    say "$JOIN: its node from ${pantheon_commit%"${pantheon_commit#???????}"}, keys for $JOIN_AGENTS"
    remote "cd ~/$JOIN_DIR && git fetch -q origin && git cat-file -e $pantheon_commit" || die "$JOIN can't get $pantheon_commit: push it to GitHub first"
    remote "cd ~/$JOIN_DIR && $(host_sh | sed 's/^cd [^&]*&& //') stop >/dev/null 2>&1; git checkout -q --detach $pantheon_commit && PATH=\$HOME/pantheon/soma/_build/install/default/bin:\$PATH && eval \"\$(opam env --switch=soma-build --set-switch)\" && soma build main.soma >/tmp/pantheon-join-build.log 2>&1" \
      || die "$JOIN: its node didn't build (/tmp/pantheon-join-build.log there)"
    remote 'P=$HOME/pantheon; [ ! -d $P/net ] || mv $P/net $P/net-saved-$(date +%Y%m%d-%H%M%S)'
    remote "$(host_sh) keygen" | tar -x -C "$net/parts" -f - || die "$JOIN: keygen failed"
  fi
  # each governed repository up to its genesis commit, which the VMs clone
  rm -rf "$net/repos"
  for name in $REPOS; do
    src=$(repo_src "$name")
    if [ "$name" = soma ]; then commit=$soma_commit; else commit=$pantheon_commit; fi
    rm -rf "$net/repos/$name.git"
    git init -q --bare "$net/repos/$name.git"
    git -C "$src" push -q "$net/repos/$name.git" "$commit:refs/heads/genesis"
    git -C "$net/repos/$name.git" symbolic-ref HEAD refs/heads/genesis
  done
  if [ ! -f "$net/network.json" ]; then
    jq --arg s "$soma_commit" --arg p "$pantheon_commit" --arg repos "$REPOS" \
      '.repos = [($repos | split(" ") | map(select(. != "")))[] | {name: ., url: "repos/\(.).git", commit: (if . == "soma" then $s else $p end)}]' \
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
  if [ -n "$JOIN" ]; then
    out=$(tar -C "$SANDBOX_DIR" -cf - network | remote_in "$(host_sh) join") || die "$JOIN: join failed: $out"
    printf '%s\n' "$out" | sed 's/^host: /sandbox: '"${JOIN#*@}"': /'
    hashes="$hashes $(printf '%s\n' "$out" | awk '/genesis/ {print $NF}')"
  fi
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
      # Grok Build's own default model unless GROK_BUILD_MODEL says otherwise
      printf '%s' "${GROK_BUILD_MODEL:+GROK_BUILD_MODEL=$GROK_BUILD_MODEL
}" | in_vm "$v" sudo sh -c 'umask 077; cat > /etc/pantheon/keys.env'
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
  in_vm "$v" sudo sh -c 'cat > /usr/local/lib/pantheon/.model-env && mv /usr/local/lib/pantheon/.model-env /usr/local/lib/pantheon/model-env' < "$here/deploy/sandbox/model-env"
  for f in bidder.sh bidder-claude.sh bidder-codex.sh bidder-grok.sh; do
    # moved into place, so a bidder that's running keeps the copy it started with
    in_vm "$v" sudo sh -c "cat > /usr/local/lib/pantheon/.$f && chmod 755 /usr/local/lib/pantheon/.$f && mv /usr/local/lib/pantheon/.$f /usr/local/lib/pantheon/$f" < "$here/scripts/$f"
  done
  in_vm "$v" sudo sh -c 'cat > /usr/local/lib/pantheon/bidder-inbox.sh.new && chmod 755 /usr/local/lib/pantheon/bidder-inbox.sh.new && mv /usr/local/lib/pantheon/bidder-inbox.sh.new /usr/local/lib/pantheon/bidder-inbox.sh' < "$here/scripts/bidder-inbox.sh"
  in_vm "$v" sudo sh -c 'cat > /usr/local/bin/pantheon-inbox.new && chmod 755 /usr/local/bin/pantheon-inbox.new && mv /usr/local/bin/pantheon-inbox.new /usr/local/bin/pantheon-inbox' < "$here/scripts/pantheon-inbox"
  in_vm "$v" sudo sh -c 'cat > /usr/local/bin/soma-dev-build.new && chmod 755 /usr/local/bin/soma-dev-build.new && mv /usr/local/bin/soma-dev-build.new /usr/local/bin/soma-dev-build' < "$here/scripts/soma-dev-build"
  in_vm "$v" sudo sh -c 'install -d -m 755 /var/lib/pantheon-build && touch /var/lib/pantheon-build/lock && chmod 644 /var/lib/pantheon-build/lock'
  # a sweeper for what a killed job leaves in /tmp (a bidder stopped at its time
  # limit never hands back its checkout): hourly, anything of Pantheon's over
  # two hours old, past any job's limit (a patch 30 minutes, CI an hour)
  in_vm "$v" sudo sh -c 'printf "[Unit]\nDescription=Remove Pantheon temporary files over two hours old\n[Service]\nType=oneshot\nExecStart=/usr/bin/find /tmp -maxdepth 1 -name pantheon-* -mmin +120 -exec rm -rf {} +\n" > /etc/systemd/system/pantheon-sweep.service; printf "[Unit]\nDescription=Hourly Pantheon /tmp sweep\n[Timer]\nOnCalendar=hourly\nPersistent=true\n[Install]\nWantedBy=timers.target\n" > /etc/systemd/system/pantheon-sweep.timer; systemctl daemon-reload; systemctl enable -q --now pantheon-sweep.timer'
  in_vm "$v" sudo sh -c 'install -d -m 755 /usr/local/lib/pantheon/bidder-bin && cat > /usr/local/lib/pantheon/bidder-bin/.soma && chmod 755 /usr/local/lib/pantheon/bidder-bin/.soma && mv /usr/local/lib/pantheon/bidder-bin/.soma /usr/local/lib/pantheon/bidder-bin/soma' < "$here/deploy/sandbox/soma-locked"
  in_vm "$v" sudo sh -c 'cat > /usr/local/sbin/pantheon-docker.new && chmod 755 /usr/local/sbin/pantheon-docker.new && mv /usr/local/sbin/pantheon-docker.new /usr/local/sbin/pantheon-docker' < "$here/deploy/sandbox/pantheon-docker"
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
    # Pantheon's build within a cloud agent's default command time (2 minutes):
    # a change that makes it slower fails CI, as a broken one does
    pantheon_ci=$(python3 "$here/deploy/ci-command.py" "$here" "${PANTHEON_CI:-timeout 120 soma build main.soma && timeout 120 test/edits.sh && sh test/ci-policy.sh && timeout 120 bash test/cli.sh && timeout 120 bash test/genesis.sh && timeout 120 bash test/double-bid.sh && timeout 120 sh test/soma-misc-runner.sh && timeout 120 sh test/host-quoting.sh}")
    printf '%s\n' "$pantheon_ci" | put ci/pantheon
    # Soma's CI is a full build: on three agents (SOMA_CI_AGENTS), so whichever
    # bids, two attestors run it, and two rejecting a broken build keep it out.
    # On two, a bidder that was one of them left a single check, which one
    # "no" can't enforce: a merge needs three approvals, a rejection two.
    governs soma || SOMA_CI_AGENTS=""
    case " $SOMA_CI_AGENTS " in
      # deploy/sandbox/soma-ci: Soma's build, then the CI image's Pantheon built
      # with it, so a change that breaks Soma's biggest user fails here
      # Then the test-suite/misc/soma_*.sh tests a bid adds or changes, by git's
      # hash against the market's Soma commit (docs/DOGFOOD-REPORT.md D-1)
      *" $a "*) printf '%s\n' "${SOMA_CI:-$(soma_ci_command)}" | put ci/soma ;;
      *) in_vm "$v" sudo rm -f /etc/pantheon/ci/soma ;;
    esac
    printf '%s\n' --bid-window 900 --max-llm-calls 200 $flags | put flags
    put goal.txt < "${GOAL_FILE:-$here/examples/dogfood/goal.txt}"
    setup_inbox "$v"
    printf '[Service]\nSyslogIdentifier=pantheon\nEnvironment="BIDDER_WRITABLE=/home/pantheon/.opam/log"\nEnvironment="PANTHEON_REPOS=%s/repos"\n' "$HOMEDIR" | in_vm "$v" sudo sh -c 'mkdir -p /etc/systemd/system/pantheon-node.service.d && cat > /etc/systemd/system/pantheon-node.service.d/log.conf && systemctl daemon-reload'
    in_vm "$v" sudo systemctl enable -q pantheon-node
    say "$a: ready, backend $b"
  done
  # all at once: restarted one after another mid-height, a node that came back
  # first can decide a block the others then miss the last votes of, and
  # catching up needs two nodes that have it
  [ -z "$JOIN" ] || cmd_forwards
  for a in $AGENTS; do in_vm "$(vm "$a")" sudo systemctl restart pantheon-node & done
  if [ -n "$JOIN" ]; then
    # the same goal as here; its nodes, inbox and mirror by host.sh
    remote_in "cat > ~/pantheon/goal.txt" < "${GOAL_FILE:-$here/examples/dogfood/goal.txt}"
    remote "$(host_sh) start" | sed "s/^host: /sandbox: ${JOIN#*@}: /" &
  fi
  wait
  say "started. Watch it with: scripts/sandbox.sh status"
}

# Soma's CI command: deploy/sandbox/soma-ci, after the hashes of the market's
# Soma commit's test-suite/misc/soma_*.sh, so it runs what a bid adds or changes
soma_ci_command() {
  b=$(git -C "$SOMA_CHECKOUT" ls-tree -r "${SOMA_COMMIT:-gradual}" test-suite/misc \
      | awk -F '\t' '$2 ~ /^test-suite\/misc\/soma_[^\/]*\.sh$/ { split($1, m, " "); printf "%s:%s ", $2, m[3] }')
  [ -n "$b" ] || die "no test-suite/misc/soma_*.sh in Soma's ${SOMA_COMMIT:-gradual} ($SOMA_CHECKOUT): Soma's CI couldn't tell which tests a bid changes"
  printf "SOMA_MISC_BASELINE='%s'\n%s\n" "$b" "$(cat "$here/deploy/sandbox/soma-ci")"
}

cmd_status() {
  [ -z "$JOIN" ] || remote "$(host_sh) status" 2>/dev/null | sed -n '/^== tasks/q;p' | sed "s/^== /== ${JOIN#*@}: /"
  for a in $AGENTS; do
    v=$(vm "$a")
    printf '== %s (%s)\n' "$a" "$(running "$v" && in_vm "$v" systemctl is-active pantheon-node 2>/dev/null || echo 'VM stopped')"
    running "$v" && as_node "$v" $NODE status $HOMEDIR 2>&1 | sed 's/^/   /' || true
    # the subscription's usage, where the model's CLI can say it headless (a
    # LIMIT line above means the node holds this model's calls)
    case $a in
      muse) running "$v" && in_vm "$v" sudo -u bidder -H muse usage 2>/dev/null | sed 's/^/   usage: /' || true ;;
    esac
  done
}

cmd_logs() { a=${1:?usage: scripts/sandbox.sh logs AGENT [LINES]}; in_vm "$(vm "$a")" sudo journalctl -u pantheon-node -t pantheon --no-pager -o cat -n "${2:-60}"; }
cmd_shell() { a=${1:?usage: scripts/sandbox.sh shell AGENT}; limactl shell "$(vm "$a")"; }
cmd_stop() {
  for a in $AGENTS; do v=$(vm "$a"); running "$v" && { in_vm "$v" sudo systemctl stop pantheon-node; limactl stop "$v" >/dev/null; say "$v stopped"; }; done
  if [ -n "$JOIN" ]; then t=$(tailnet_ip); for a in $AGENTS; do pkill -f -- "-L $t:$(agent_port "$a"):" 2>/dev/null || true; done; remote "$(host_sh) stop" | sed "s/^host: /sandbox: ${JOIN#*@}: /"; fi
  true
}

# What the chain merged, saved before its homes go: each repository's head on
# one node, as pantheon/saved-STAMP in your checkout, unless your checkout's
# HEAD already has it. A reset that can't save stops, unless FORCE_RESET=1.
save_chain() {
  a=$(echo $AGENTS | cut -d' ' -f1); v=$(vm "$a")
  running "$v" && in_vm "$v" sudo test -d $HOMEDIR/repos || return 0
  stamp=$(date +%Y%m%d-%H%M%S)
  export GIT_SSH_COMMAND="ssh -F $HOME/.lima/$v/ssh.config"
  for name in $REPOS; do
    dst=$(repo_src "$name") ref=refs/heads/pantheon/saved-$stamp
    if ! git -C "$dst" fetch -q --upload-pack "sudo -u pantheon git-upload-pack" "lima-$v:$HOMEDIR/repos/$name" "HEAD:$ref"; then
      [ "${FORCE_RESET:-}" = 1 ] || die "couldn't save $name's chain head from $a before discarding the chain: fix that, or FORCE_RESET=1 to discard it anyway"
      continue
    fi
    if git -C "$dst" merge-base --is-ancestor "$ref" HEAD; then git -C "$dst" update-ref -d "$ref"
    else say "$name: the chain's merges are saved as pantheon/saved-$stamp ($(git -C "$dst" rev-list --count HEAD.."$ref") commits your checkout doesn't have): merge them into the default branch"
    fi
  done
}

# A new chain needs new homes, as on real machines: this discards every
# node's keys, blocks and checkouts, and the network directory. The VMs stay.
# What the chain merged is saved first (save_chain).
cmd_reset() {
  save_chain
  for a in $AGENTS; do
    v=$(vm "$a"); running "$v" || continue
    # disabled, so a VM's restart can't start a node on the next genesis with
    # the last run's settings before start writes this run's
    in_vm "$v" sudo systemctl disable -q --now pantheon-node
    in_vm "$v" sudo rm -rf $HOMEDIR /var/lib/pantheon/network
  done
  rm -rf "$SANDBOX_DIR/network"
  say "the chain is gone. Next: scripts/sandbox.sh network"
}

# A new epoch, in place: what the last chain merged into Soma becomes the
# toolchain, so Pantheon can use it. Each VM keeps its logins (a fresh base
# VM would need every model logged in again): its Soma is rebuilt from
# SOMA_COMMIT, the CI image is built once and copied to the others, its node
# from PANTHEON_COMMIT, and a new chain starts at both commits.
cmd_epoch() {
  soma_commit=$(git -C "$SOMA_CHECKOUT" rev-parse "${SOMA_COMMIT:?set SOMA_COMMIT: the Soma commit the epoch builds, e.g. pantheon/merged}")
  pantheon_commit=$(git -C "$here" rev-parse "${PANTHEON_COMMIT:?set PANTHEON_COMMIT: the Pantheon commit the epoch starts from}")
  say "epoch: Soma $(git -C "$SOMA_CHECKOUT" log -1 --format='%h %s' "$soma_commit" | cut -c1-70)"
  say "epoch: Pantheon $(git -C "$here" log -1 --format='%h %s' "$pantheon_commit" | cut -c1-70)"
  for a in $AGENTS; do running "$(vm "$a")" || die "$(vm "$a") isn't running"; in_vm "$(vm "$a")" sudo systemctl disable -q --now pantheon-node; done
  say "rebuilding Soma in every VM (a few minutes)"
  mkdir -p "$SANDBOX_DIR"; rm -f "$SANDBOX_DIR"/epoch-*
  pids=""
  for a in $AGENTS; do
    v=$(vm "$a")
    ( git -C "$SOMA_CHECKOUT" archive --format=tar "$soma_commit" | in_vm "$v" sudo -u pantheon -H sh -c \
        'cd ~/soma && find . -mindepth 1 -maxdepth 1 ! -name _build -exec rm -rf {} + && tar -x -f - && eval "$(opam env --switch=soma-build --set-switch)" && make dunestrap >/tmp/epoch-soma.log 2>&1 && dune build -j 2 soma-runtime.install soma-core.install >>/tmp/epoch-soma.log 2>&1' \
      && in_vm "$v" sudo chmod -R a+rX /home/pantheon/soma && echo ok > "$SANDBOX_DIR/epoch-$a" ) &
    pids="$pids $!"
  done
  wait $pids
  for a in $AGENTS; do [ -f "$SANDBOX_DIR/epoch-$a" ] || die "Soma didn't build on $(vm "$a"): scripts/sandbox.sh shell $a, then: sudo cat /tmp/epoch-soma.log"; done
  first=$(vm "$(echo $AGENTS | cut -d' ' -f1)")
  say "building the CI image pantheon:dev in $first (a while), then copying it to the others"
  tmp=$(mktemp -d); git -C "$here" archive --format=tar "$pantheon_commit" > "$tmp/pantheon.tar"; git -C "$SOMA_CHECKOUT" archive --format=tar "$soma_commit" > "$tmp/soma.tar"
  in_vm "$first" sudo sh -c 'rm -rf /tmp/ci && mkdir -p /tmp/ci/pantheon /tmp/ci/soma'
  in_vm "$first" sudo tar -x -C /tmp/ci/pantheon -f - < "$tmp/pantheon.tar"
  in_vm "$first" sudo tar -x -C /tmp/ci/soma -f - < "$tmp/soma.tar"
  rm -rf "$tmp"
  in_vm "$first" sudo sh -c 'docker build -q -f /tmp/ci/pantheon/deploy/Dockerfile --build-context soma=/tmp/ci/soma -t pantheon:dev /tmp/ci/pantheon >/tmp/epoch-image.log 2>&1 && rm -rf /tmp/ci' \
    || die "the CI image didn't build in $first: sudo cat /tmp/epoch-image.log there"
  # each epoch's image replaces the last, which stays behind untagged: prune
  # those, or a few epochs fill a VM's disk and the next load fails midway
  in_vm "$first" sudo docker image prune -f >/dev/null
  for a in $AGENTS; do v=$(vm "$a"); [ "$v" = "$first" ] && continue
    in_vm "$v" sudo docker image prune -f >/dev/null
    in_vm "$first" sudo docker save pantheon:dev | in_vm "$v" sudo docker load >/dev/null \
      || die "copying the CI image to $v failed: check its disk (limactl shell $v df -h /), then run the epoch again"
    in_vm "$v" sudo docker image prune -f >/dev/null
  done
  # every node rebuilt with the new Soma, whatever commit it had
  for a in $AGENTS; do in_vm "$(vm "$a")" sudo -u pantheon sh -c 'rm -rf ~/pantheon/.commit ~/pantheon/.soma-cache'; done
  cmd_reset
  PANTHEON_COMMIT=$pantheon_commit SOMA_COMMIT=$soma_commit cmd_network
  say "epoch ready. Start it: GOAL_FILE=... scripts/sandbox.sh start"
}

# Publish through the same scratch merge logic as the network's mirror.
cmd_fetch() {
  a=${1:-$(echo $AGENTS | cut -d' ' -f1)}; v=$(vm "$a")
  export GIT_SSH_COMMAND="ssh -F $HOME/.lima/$v/ssh.config"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  for name in $REPOS; do
    dst=$(repo_src "$name")
    git init -q --bare "$tmp/$name.git"
    # --git-dir: -C on a bare repository fails under safe.bareRepository=explicit
    if git --git-dir="$tmp/$name.git" fetch -q --upload-pack "sudo -u pantheon git-upload-pack" "lima-$v:$HOMEDIR/repos/$name" HEAD; then
      git --git-dir="$tmp/$name.git" update-ref HEAD FETCH_HEAD
      PUBLISH_DIR="$tmp/publish" sh "$here/scripts/publish.sh" "$tmp/$name.git" "$dst" \
        || say "$dst: couldn't publish from $a (see above)"
    else
      say "$dst: couldn't fetch from $a (see above)"
    fi
  done
  rm -rf "$tmp"; trap - EXIT
}

c=${1:-}; [ $# -gt 0 ] && shift
case $c in
  base|nodes|network|update|login|session|start|status|logs|shell|stop|fetch|reset|epoch|forwards) "cmd_$c" "$@" ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; [ -z "$c" ] || exit 1 ;;
esac
