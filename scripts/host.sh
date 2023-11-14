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
# Nothing listens beyond localhost, unless the host joins a network made
# elsewhere (keygen, join): then its nodes listen on LISTEN, its tailnet address.
#
#   scripts/host.sh users              provision isolated accounts and inbox groups (root; HOST_DRY=DIR to preview)
#   scripts/host.sh permissions        restrict existing node homes and secrets (HOST_DRY=DIR to preview)
#   scripts/host.sh network            keys, the network and its genesis (once), for Pantheon at HEAD
#   scripts/host.sh keygen             to join a network made elsewhere: this host's agents' keys, their
#                                      addresses on LISTEN; prints each one's public part as NAME.json, as tar
#   scripts/host.sh join               the network directory (as tar, on stdin) that holds every agent's
#                                      part: each node's genesis from it, and the genesis hash
#   scripts/host.sh start              write the services and (re)start them all: nodes, mirror, inbox server
#   scripts/host.sh services           nodes, mirror and inbox server as the pantheon user, as system services (root; HOST_DRY=DIR to preview)
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
#   AGENTS        this host's agents (default: claude codex grok muse); a name's provider is the part
#                 before a dash, so claude-zucc is Claude Code
#   LISTEN        the address the nodes listen on (default 127.0.0.1); keygen gives it to the others
#   BASE_PORT     the first agent's port for keygen (default 26711), one per agent after it
#   VM_AGENTS     the agents that work from a VM on this host (default: muse)
#   REMOTE        the GitHub repository workers share (default: this checkout's origin)
#   CODEX_ENV     the Codex Cloud environment for codex's workers (codex cloud lists them)
#   GROK_MODEL    the Cursor CLI's model for grok (default: grok; cursor-agent models lists them)
#   SOMA_REMOTE   Soma's repository, for the agents to read (default: https://github.com/yevbar/soma.git)
#   BRANCH        the branch of REMOTE the market publishes to and workers start from (default: its default branch)
#   SOMA_REF      the branch there at the commit SOMA_DIR is built from (default: gradual, Soma's default branch)
#   EXCLUDE       repositories outside this host's agents' scope, e.g. "soma" on a host with no room for
#                 its build: keygen puts them in each part's "exclude", so genesis has the market leave
#                 those repositories' tasks to other agents (no bids, picks or checks here; default: none)
# or from PANTHEON_HOST/host.env (lines like CODEX_ENV=soma), read first.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
P=${PANTHEON_HOST:-$HOME/pantheon}
[ ! -f "$P/host.env" ] || . "$P/host.env"
NET=$P/net AGENTS=${AGENTS:-claude codex grok muse}
# the operator account that may act as the node and diplomat users (sudoers):
# who ran sudo, not root; an explicit HOST_OPERATOR=root is the only way root
# is named, since a root-run default would leave the operator unable to act
if [ -n "${HOST_OPERATOR:-}" ]; then HOST_OPERATOR_GIVEN=1; else HOST_OPERATOR=${SUDO_USER:-$(id -un 2>/dev/null || echo operator)}; HOST_OPERATOR_GIVEN=; fi
# an agent's provider: its name up to a dash (claude-zucc is claude)
kind() { printf '%s' "${1%%-*}"; }
VM_AGENTS=${VM_AGENTS:-$(for a in $AGENTS; do [ "$(kind "$a")" != muse ] || printf '%s ' "$a"; done)}
LISTEN=${LISTEN:-127.0.0.1} BASE_PORT=${BASE_PORT:-26711}
BIN=$here/main.exe SOMA=${SOMA_DIR:-$P/soma}
CI_MEMORY=${CI_MEMORY:-1536m}
EXCLUDE=${EXCLUDE:-}
CI_CMD=$(python3 "$here/deploy/ci-command.py" "$here" "${PANTHEON_CI:-timeout 120 soma build main.soma && timeout 120 test/edits.sh && sh test/ci-policy.sh && timeout 120 bash test/cli.sh && timeout 120 bash test/genesis.sh && timeout 120 bash test/double-bid.sh && timeout 120 bash test/parallel-tasks.sh && timeout 120 bash test/scopes.sh && timeout 120 sh test/soma-misc-runner.sh && timeout 120 sh test/host-quoting.sh}")
PORT=${INBOX_PORT:-8787}
# a Lima VM (plain, user-mode network) reaches the host's localhost here
VM_HOST=192.168.5.2
REMOTE=${REMOTE:-$(git -C "$here" remote get-url origin 2>/dev/null || true)}
# the branch the market publishes to and workers start from: REMOTE's default
# branch, so the market's work is where everyone looks
BRANCH=${BRANCH:-$( [ -n "$REMOTE" ] && git ls-remote --symref "$REMOTE" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\(.*\)	HEAD$|\1|p')}
BRANCH=${BRANCH:-master}
# BRANCH reaches a shell wrapper, a unit file and git's command line, and
# comes from the remote (docs/SECURITY-REVIEW-2.md P-11): a plain ref name or nothing
valid_branch() {
  case $1 in ''|-*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  git check-ref-format --branch "$1" >/dev/null 2>&1
}
valid_branch "$BRANCH" || { printf 'host: BRANCH %s is not a plain git branch name (letters, digits, . _ / -): set BRANCH to one\n' "$(printf '%s' "$BRANCH" | tr -c 'A-Za-z0-9._/-' '?')" >&2; exit 1; }
CODEX_ENV=${CODEX_ENV:-}
GROK_MODEL=${GROK_MODEL:-grok}
SOMA_REMOTE=${SOMA_REMOTE:-https://github.com/yevbar/soma.git}
SOMA_REF=${SOMA_REF:-gradual}
soma_commit() { git -C "$SOMA" rev-parse HEAD 2>/dev/null || echo unknown; }
# whether the network's genesis governs Soma too (scripts/sandbox.sh's JOIN
# makes one that does), and whether this host's agents have it in scope
governs_soma() { jq -e '.repos[] | select(.name == "soma")' "$NET/${AGENTS%% *}/genesis.json" >/dev/null 2>&1; }
excludes_soma() { case " $EXCLUDE " in *" soma "*) true ;; *) false ;; esac; }
soma_scope() {
  if governs_soma && excludes_soma; then
    printf '%s' "This network governs Soma too, but Soma is outside this host's scope (EXCLUDE in host.env, so each agent's genesis part excludes it): this host has no room to build it, so the market doesn't ask its agents to bid on Soma's tasks, and its leaders leave Soma's bids to leaders on the other host, whose nodes build Soma. {{SOMA_DIR}} is for reading. A Soma bug or gap you find while working on Pantheon goes in {{SOMA_NOTES}}: what you tried, what happened, and the smallest example; those become Soma's tasks."
  elif governs_soma; then
    printf '%s' "This network governs Soma too: its .plan has Soma's items (Sandbox's pieces for the unikernel, first), and a task on Soma comes with a checkout of Soma in the request, the market's head, which is what you change; {{SOMA_DIR}} is for reading. Keep a Soma patch small, read the tests near what you change, and add a test-suite/misc/soma_*.sh test, which CI runs; a rejection says what failed. A Soma bug you find while working on Pantheon goes in {{SOMA_NOTES}} too: what you tried, what happened, and the smallest example."
  else
    printf '%s' "This network governs Pantheon only: no one changes Soma through it. If you or a worker find a Soma bug, a missing feature, or a place where the language fights you, add a line to \`{{SOMA_NOTES}}\`: what you tried, what happened, and the smallest example you have. Those become Soma's next work."
  fi
}
UNITS=$HOME/.config/systemd/user
export PATH="$HOME/.local/bin:$PATH"
say() { printf 'host: %s\n' "$*"; }
die() { printf 'host: %s\n' "$*" >&2; exit 1; }
need_bin() { [ -x "$BIN" ] || die "no $BIN: build Pantheon first (SOMA_DIR=$SOMA scripts/setup-node.sh)"; }
in_vm_agents() { case " $VM_AGENTS " in *" $1 "*) return 0 ;; esac; return 1; }
is_agent() { case " $AGENTS " in *" $1 "*) return 0 ;; esac; return 1; }
vm() { printf 'pantheon-%s' "$(kind "$1")"; }
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Emit the same permission operations for deployment and for rootless CI.
# This is only the modes part of P-1; it does not separate Unix identities.
cmd_permissions() {
  if [ -n "${HOST_DRY:-}" ]; then
    mkdir -p "$HOST_DRY"
    permissions_script > "$HOST_DRY/permissions.sh"
  else
    permissions_script | sh -eu
  fi
}
# The generated script checks every path before its first mutation. Walk
# ancestors too: a regular key below a symlinked net/ is still unsafe.
path_guard() {
  cat <<'GUARD'
reject_links() {
  path=$1
  while :; do
    [ ! -L "$path" ] || { echo "host: symlinked path $path" >&2; exit 1; }
    case $path in /|.|'') break ;; esac
    parent=$(dirname -- "$path")
    [ "$parent" != "$path" ] || break
    path=$parent
  done
}
GUARD
}
permissions_script() {
  printf '#!/bin/sh\nset -eu\n'
  path_guard
  for a in $AGENTS; do
    printf 'reject_links %s\n' "$(q "$NET/$a/key.json")"
  done
  printf 'reject_links %s\n' "$(q "$P/inbox.json")"
  for a in $AGENTS; do
    h=$(q "$NET/$a")
    printf '[ ! -d %s ] || chmod 0700 %s\n' "$h" "$h"
    k=$(q "$NET/$a/key.json")
    printf '[ ! -f %s ] || chmod 0600 %s\n' "$k" "$k"
  done
  k=$(q "$P/inbox.json")
  printf '[ ! -f %s ] || chmod 0600 %s\n' "$k" "$k"
}

# Provision identities independently of migrating a running deployment. These
# accounts are deliberately not used by the legacy user services yet.
valid_agent_names() {
  for a in $AGENTS; do
    case $a in ''|*[!a-z0-9-]*|-*) die "unsafe agent name for a Unix account: $a" ;; esac
    [ ${#a} -le 23 ] || die "agent name too long for a Unix account: $a"
  done
}

cmd_users() {
  case $HOST_OPERATOR in ''|*[!a-z0-9_-]*|-*) die "unsafe operator name for the sudoers file: $HOST_OPERATOR" ;; esac
  if [ "$HOST_OPERATOR" = root ] && [ -z "$HOST_OPERATOR_GIVEN" ]; then
    die "the operator for the sudoers file would be root (from SUDO_USER/id): set HOST_OPERATOR to your own account, or explicitly to root if that is really the operator"
  fi
  for a in $AGENTS; do
    case $a in ''|*[!a-z0-9-]*|-*) die "unsafe agent name for a Unix account: $a" ;; esac
    [ ${#a} -le 23 ] || die "agent name too long for a Unix account: $a"
  done
  if [ -n "${HOST_DRY:-}" ]; then
    mkdir -p "$HOST_DRY"
    users_script > "$HOST_DRY/users.sh"
  else
    [ "$(id -u)" = 0 ] || die "users requires root (or HOST_DRY=DIR to preview)"
    users_script | sh -eu
  fi
}
users_script() {
  printf '#!/bin/sh\nset -eu\n'
  path_guard
  # Check even currently absent leaves, before account creation or install
  # changes a directory. Existing private homes must never redirect root.
  for path in /var/lib/pantheon/.ssh /var/lib/pantheon-diplomats /var/lib/pantheon-inbox /etc/sudoers.d/pantheon; do
    printf 'reject_links %s\n' "$(q "$path")"
  done
  for a in $AGENTS; do
    printf 'reject_links %s\n' "$(q "/var/lib/pantheon-diplomats/$a")"
    printf 'reject_links %s\n' "$(q "/var/lib/pantheon-inbox/$a")"
  done
  cat <<'ROOT'
# Refuse to adopt an unrelated existing account or a symlinked home.
account() {
  name=$1 home=$2
  if getent passwd "$name" >/dev/null; then
    actual=$(getent passwd "$name" | cut -d: -f6)
    [ "$actual" = "$home" ] || { echo "host: $name has unexpected home $actual" >&2; exit 1; }
  else
    useradd --user-group --create-home --home-dir "$home" --shell /bin/sh "$name"
  fi
  [ ! -L "$home" ] || { echo "host: symlinked home $home" >&2; exit 1; }
  chown "$name" "$home"
}
account pantheon /var/lib/pantheon
# Traversable so shared builds and repositories can live below it. Secrets
# belong in net/AGENT (0700), inbox.json (0600), and .ssh (0700).
chmod 0711 /var/lib/pantheon
install -d -o pantheon -m 0700 /var/lib/pantheon/.ssh
install -d -o root -m 0711 /var/lib/pantheon-diplomats
install -d -o root -m 0711 /var/lib/pantheon-inbox
ROOT
  for a in $AGENTS; do
    cat <<ROOT
getent group inbox-$a >/dev/null || groupadd inbox-$a
account pantheon-$a /var/lib/pantheon-diplomats/$a
chmod 0700 /var/lib/pantheon-diplomats/$a
usermod -a -G inbox-$a pantheon
usermod -a -G inbox-$a pantheon-$a
install -d -o pantheon -g inbox-$a -m 2770 /var/lib/pantheon-inbox/$a
ROOT
  done
  # The operator acts as the node and diplomat users (and starts a
  # diplomat's session as that user) through this one sudoers file;
  # nobody else gets a path in. Written last, after every account
  # exists, so a refused account leaves no sudoers behind.
  runas=pantheon; for a in $AGENTS; do runas="$runas,pantheon-$a"; done
  sudo_line="$HOST_OPERATOR ALL=($runas) NOPASSWD: ALL"
  printf 'host_sudo=$(mktemp)\n'
  printf 'printf "%%s\\n" %s > "$host_sudo"\n' "$(q "$sudo_line")"
  printf 'if command -v visudo >/dev/null 2>&1; then visudo -cf "$host_sudo" >/dev/null; fi\n'
  printf 'install -o root -g root -m 0440 "$host_sudo" /etc/sudoers.d/pantheon\n'
  printf 'rm -f "$host_sudo"\n'
}

# Nodes, mirror and inbox server as the pantheon user (system services).
# Like users, this emits one root script; HOST_DRY previews it and a
# rootless test can run it against a fixture root with stubbed tools.
cmd_services() {
  valid_agent_names
  if [ -n "${HOST_DRY:-}" ]; then
    mkdir -p "$HOST_DRY"
    services_script > "$HOST_DRY/services.sh"
  else
    [ "$(id -u)" = 0 ] || die "services requires root (or HOST_DRY=DIR to preview)"
    services_script | sh -eu
  fi
}

services_script() {
  printf '#!/bin/sh\nset -eu\nR=${HOST_ROOT:-}\n'
  cat <<'ROOT'
# Refuse symlinked or missing destinations before any root write: a
# node-owned symlink must never be followed by root.
refuse_link() { [ ! -L "$1" ] || { echo "host: refusing symlinked path $1" >&2; exit 1; }; }
refuse_link "$R/var/lib/pantheon"
refuse_link "$R/var/lib/pantheon/inbox.json"
refuse_link "$R/var/lib/pantheon/goal.txt"
ROOT
  for a in $AGENTS; do
    printf '[ -d "$R/var/lib/pantheon/net/%s" ] || { echo "host: no node home for %s under /var/lib/pantheon/net (make the network there first)" >&2; exit 1; }\n' "$a" "$a"
    printf 'refuse_link "$R/var/lib/pantheon/net/%s"\n' "$a"
    for f in key.json run.sh backend.sh; do
      printf 'refuse_link "$R/var/lib/pantheon/net/%s/%s"\n' "$a" "$f"
    done
  done
  # What the units point at must be reachable by pantheon, checked as
  # pantheon itself, before any write below.
  printf 'runuser -u pantheon -- test -x %s || { echo "host: pantheon cannot execute the node binary: install Pantheon where the pantheon user can read it" >&2; exit 1; }\n' "$(q "$BIN")"
  for tool_path in "$here/scripts/host.sh" "$here/deploy/host/ci-sandbox" "$here/scripts/bidder-inbox.sh" "$here/scripts/inbox-http.py"; do
    printf 'runuser -u pantheon -- test -r %s || { echo "host: pantheon cannot read %s: install Pantheon where the pantheon user can read it" >&2; exit 1; }\n' "$(q "$tool_path")" "$(q "$tool_path")"
  done
  cat <<'ROOT'
# Everything is built in a root-only stage, then installed into place.
# Per-node files arrive over runuser's stdin: root reads its own stage
# (0700, never traversed by pantheon) and pantheon writes its own files.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
uid=$(id -u pantheon)
install -d -o pantheon -m 0700 "$R/var/lib/pantheon/.ssh"
ROOT
  for a in $AGENTS; do
    printf 'install -d -o pantheon -m 0700 "$R/var/lib/pantheon/net/%s"\n' "$a"
  done
  printf 'cat > "$stage/pantheon-node@.service" <<EOF\n'
  cat <<'UNIT'
[Unit]
Description=Pantheon node %i
[Service]
User=pantheon
WorkingDirectory=/var/lib/pantheon/net/%i
Environment=SOMA_DIR=/var/lib/pantheon/soma
Environment=XDG_RUNTIME_DIR=/run/user/$uid
ExecStart=/var/lib/pantheon/net/%i/run.sh
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
  printf 'EOF\ninstall -o root -g root -m 0644 "$stage/pantheon-node@.service" "$R/etc/systemd/system/pantheon-node@.service"\n'
  if [ -n "$REMOTE" ]; then
    printf 'cat > "$stage/pantheon-mirror.service" <<EOF\n'
    printf '[Unit]\nDescription=Pantheon mirror\n[Service]\nUser=pantheon\nEnvironment=PANTHEON_HOST=/var/lib/pantheon\nExecStart=%s/scripts/host.sh mirror-loop\nRestart=on-failure\nRestartSec=60\n[Install]\nWantedBy=multi-user.target\nEOF\n' "$here"
    printf 'install -o root -g root -m 0644 "$stage/pantheon-mirror.service" "$R/etc/systemd/system/pantheon-mirror.service"\n'
  fi
  if [ -n "$VM_AGENTS" ]; then
    printf 'cat > "$stage/pantheon-inbox.service" <<EOF\n'
    printf '[Unit]\nDescription=Pantheon inbox server\n[Service]\nUser=pantheon\nExecStart=/usr/bin/python3 %s/scripts/inbox-http.py serve /var/lib/pantheon/inbox.json\nRestart=on-failure\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\nEOF\n' "$here"
    printf 'install -o root -g root -m 0644 "$stage/pantheon-inbox.service" "$R/etc/systemd/system/pantheon-inbox.service"\n'
  fi
  for a in $AGENTS; do
    exec_line="exec $BIN node /var/lib/pantheon/net/$a --backend cmd:/var/lib/pantheon/net/$a/backend.sh --goal /var/lib/pantheon/goal.txt --listen $LISTEN --ci-repo pantheon $CI_CMD --ci-sandbox $here/deploy/host/ci-sandbox --ci-memory $CI_MEMORY"
    printf 'printf "%%s\\n" %s %s > "$stage/run-%s.sh"\n' "$(q '#!/bin/sh')" "$(q "$exec_line")" "$a"
    printf 'printf "%%s\\n" %s %s > "$stage/backend-%s.sh"\n' "$(q '#!/bin/sh')" "$(q "PANTHEON_INBOX=/var/lib/pantheon-inbox/$a PANTHEON_INBOX_GROUP=inbox-$a exec $here/scripts/bidder-inbox.sh")" "$a"
    printf 'runuser -u pantheon -- sh -c %s sh "$R/var/lib/pantheon/net/%s/run.sh" < "$stage/run-%s.sh"\n' "$(q 'cat > "$1" && chmod 0755 "$1"')" "$a" "$a"
    printf 'runuser -u pantheon -- sh -c %s sh "$R/var/lib/pantheon/net/%s/backend.sh" < "$stage/backend-%s.sh"\n' "$(q 'cat > "$1" && chmod 0755 "$1"')" "$a" "$a"
  done
  cat <<'ROOT'
# ci-sandbox runs a user service for a check: pantheon's user manager
# must exist (linger starts it at boot and gives it /run/user/UID).
loginctl enable-linger pantheon
ROOT
  printf 'op=%s\n' "$(q "$HOST_OPERATOR")"
  printf 'legacy="pantheon-mirror.service pantheon-inbox.service"; for a in %s; do legacy="$legacy pantheon-node@$a.service"; done\n' "$AGENTS"
  cat <<'ROOT'
# No second copy of a node under the operator's user units after a reboot.
if [ "$op" != root ] && [ "$op" != pantheon ]; then
  runuser -u "$op" -- env "XDG_RUNTIME_DIR=/run/user/$(id -u "$op")" systemctl --user disable --now $legacy \
    || { echo "host: could not disable the operator's legacy user units; not enabling a second copy" >&2; exit 1; }
fi
systemctl daemon-reload
ROOT
  units=""; for a in $AGENTS; do units="$units pantheon-node@$a.service"; done
  [ -n "$REMOTE" ] && units="$units pantheon-mirror.service"
  [ -n "$VM_AGENTS" ] && units="$units pantheon-inbox.service"
  printf 'systemctl enable --now%s\n' "$units"
}


cmd_network() {
  need_bin
  [ ! -d "$NET" ] || die "$NET already holds a network. A new chain is a new network: stop it, move $NET away, and run this again"
  commit=$(git -C "$here" rev-parse HEAD)
  # the cloud run's parameters (examples/network/network.json): an hour's
  # term, attest window and stuck-task limit; fallback after 15 minutes
  "$BIN" init "$NET" --repo "pantheon=$here" --base-port 26701 --block-ms 1000 \
    --param term_blocks=3600 --param max_merges=2 --param stall_blocks=1800 --param attest_window=3600 \
    --param fallback_blocks=900 --param reveal_window=30 --param bid_cooldown=5 --param max_open_tasks=2 \
    --param merge_approvals=1
  cmd_permissions
  [ -f "$P/goal.txt" ] || cp "$here/examples/cloud/goal.txt" "$P/goal.txt"
  mkdir -p "$P/inbox"; for a in $AGENTS; do mkdir -p "$P/inbox/$a"; done
  say "a network for Pantheon at $(git -C "$here" log -1 --format='%h %s' "$commit"); goals in $P/goal.txt"
  say "next: scripts/host.sh start, then scripts/host.sh vm muse, then scripts/host.sh diplomats (from a herdr pane)"
}

# Joining a network made elsewhere (scripts/sandbox.sh with JOIN): keys here,
# their public parts to the maker, and back the network directory, from which
# each node computes the same genesis as every other agent's
cmd_keygen() {
  need_bin
  [ ! -d "$NET" ] || die "$NET already holds a network: stop it and move $NET away first"
  [ "$LISTEN" != 127.0.0.1 ] || die "set LISTEN to this host's address the other agents reach (its tailnet address: tailscale ip -4)"
  i=0; out=$(mktemp -d)
  for a in $AGENTS; do
    mkdir -p "$NET/$a"
    "$BIN" keygen "$NET/$a" --name "$a" --addr "$LISTEN:$((BASE_PORT + i))" >/dev/null
    # the part says which repositories are outside this agent's scope; the
    # network's maker keeps only those its network governs
    jq --arg ex "$EXCLUDE" '. + (($ex | split(" ") | map(select(. != ""))) as $l | if $l == [] then {} else {exclude: $l} end)' \
      "$NET/$a/public.json" > "$out/$a.json"; i=$((i + 1))
  done
  cmd_permissions
  tar -C "$out" -cf - . ; rm -rf "$out"
}

cmd_join() {
  need_bin
  [ -d "$NET" ] || die "no keys yet: scripts/host.sh keygen first"
  rm -rf "$P/joined"; mkdir -p "$P/joined"; tar -x -C "$P/joined" -f -
  [ -d "$P/joined/network/parts" ] || die "the tar on stdin has no network/parts: send the maker's network directory"
  for a in $AGENTS; do
    h=$("$BIN" genesis "$NET/$a" "$P/joined/network" 2>&1 | grep -o 'genesis hash [0-9a-f]*' | awk '{print $3}')
    [ -n "$h" ] || die "$a: genesis failed: $BIN genesis $NET/$a $P/joined/network"
    say "$a: genesis $h"
  done
  cmd_permissions
  mkdir -p "$P/inbox"; for a in $AGENTS; do mkdir -p "$P/inbox/$a"; done
}

# the instructions a diplomat on this host follows, for its provider
render_diplomat() {
  a=$1; mkdir -p "$P/diplomats" "$P/desk/$a"
  # a plain clone of the shared repository: cloud hand-offs start from the
  # GitHub remote and branch of the directory they run in
  [ -z "$REMOTE" ] || [ -d "$P/desk/$a/pantheon/.git" ] || git clone -q "$REMOTE" "$P/desk/$a/pantheon" \
    || say "$a: can't clone $REMOTE into $P/desk/$a/pantheon: its cloud hand-offs need it"
  d=$here/deploy/host/delegate/$(kind "$a").md
  # some agent CLIs (codex) give their commands only a few of their own
  # environment variables: the inbox's settings go in a wrapper instead
  # every value quoted: REMOTE and BRANCH come from the remote (P-11)
  cat > "$P/desk/$a/pantheon-inbox" <<W
#!/bin/sh
PANTHEON_INBOX=$(q "$P/inbox/$a") PANTHEON_REMOTE=$(q "$REMOTE") PANTHEON_BRANCH=$(q "$BRANCH") PANTHEON_CHECK=$(q "$here/scripts/host.sh check") \\
  exec $(q "$here/scripts/pantheon-inbox") "\$@"
W
  chmod 755 "$P/desk/$a/pantheon-inbox"
  # the values reach Python through its environment, never its source
  R_AGENT=$a R_REMOTE=$REMOTE R_BRANCH=$BRANCH R_NET=$NET R_CODEX_ENV=${CODEX_ENV:-ENV_ID} R_DESK=$P/desk/$a \
  R_SOMA_REMOTE=$SOMA_REMOTE R_SOMA_REF=$SOMA_REF R_SOMA_DIR=$SOMA R_SOMA_COMMIT=$(soma_commit) \
  R_SOMA_NOTES=$P/soma-notes.md R_GROK_MODEL=$GROK_MODEL R_SOMA_SCOPE=$(soma_scope) \
  python3 - "$here/deploy/host/diplomat.md" "$d" "$P/diplomats/$a.md" <<'PY'
import sys, os
t = open(sys.argv[1]).read()
d = open(sys.argv[2]).read() if os.path.exists(sys.argv[2]) else "## How you hand off\n\nYou have no workers elsewhere: do patches by hand, small, and skip what's too big."
t = t.replace("{{DELEGATE}}", d.strip())
# the inbox command by its full path: the wrapper with this agent's settings
t = t.replace("pantheon-inbox ", "{{DESK}}/pantheon-inbox ").replace("`pantheon-inbox`", "`{{DESK}}/pantheon-inbox`")
t = t.replace("{{SOMA_SCOPE}}", os.environ["R_SOMA_SCOPE"])
for k in ["AGENT", "REMOTE", "BRANCH", "NET", "CODEX_ENV", "DESK", "SOMA_REMOTE", "SOMA_REF",
          "SOMA_DIR", "SOMA_COMMIT", "SOMA_NOTES", "GROK_MODEL"]:
    t = t.replace("{{%s}}" % k, os.environ["R_" + k])
open(sys.argv[3], "w").write(t)
PY
}

cmd_start() {
  need_bin
  [ -d "$NET" ] || die "no network yet: scripts/host.sh network"
  cmd_permissions
  for a in $AGENTS; do
    # the node strips PANTHEON_* from a backend's environment: the backend sets its own
    if in_vm_agents "$a"; then url="INBOX_URL=http://$VM_HOST:$PORT "; else url=""; fi
    cat > "$NET/$a/backend.sh" <<B
#!/bin/sh
PANTHEON_INBOX=$P/inbox/$a ${url}exec $here/scripts/bidder-inbox.sh
B
    cat > "$NET/$a/run.sh" <<R
#!/bin/sh
exec $BIN node $NET/$a --backend cmd:$NET/$a/backend.sh --goal $P/goal.txt --listen $LISTEN \\
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
    (umask 077; [ -f "$P/inbox.json" ] || printf '{"listen": "127.0.0.1:%s", "url": "", "agents": {}}\n' "$PORT" > "$P/inbox.json")
    cmd_permissions
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
  r=$NET/${AGENTS%% *}/repos/pantheon
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
  case $(kind "$a") in
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
  (umask 077; [ -f "$P/inbox.json" ] || printf '{"listen": "127.0.0.1:%s", "url": "", "agents": {}}\n' "$PORT" > "$P/inbox.json")
  cmd_permissions
  tmp=$(mktemp -d); umask 077
  # a token once; NEW_TOKEN=1 replaces it (a running session then loses its inbox)
  if [ -n "${NEW_TOKEN:-}" ] || ! limactl shell "$v" test -s pantheon/token 2>/dev/null; then
    python3 "$here/scripts/inbox-http.py" token "$P/inbox.json" "$a" "$P/inbox/$a" > "$tmp/token"; tok="a new token (the old one, if any, no longer works)"
  else tok="its token as it was"; fi
  { sed -e "s|{{AGENT}}|$a|g" -e "s|{{URL}}|http://$VM_HOST:$PORT|g" "$here/deploy/cloud/agent.md"
    printf '\nYour token is in the file ~/pantheon/token: send it as -H "Authorization: Bearer $(cat ~/pantheon/token)". This VM is your machine: work in it as you like.\n'
    printf '\n## Soma, the language Pantheon is written in\n\nSoma is a fork of the Rocq Prover with gradual dependent types, and its source is its documentation: ~/soma is the commit the network builds with (%s; not built here). Start with README.md, GRADUAL.md, gradual-coverage.md, vision.md and examples/; test-suite/ and theories/ show how a feature behaves. When a task leans on a Soma feature, look it up there instead of guessing from Rocq you remember: this fork differs. %s\n' "$(soma_commit)" "$(if governs_soma && excludes_soma; then echo 'This network governs Soma too, but Soma is outside this host'"'"'s scope (its genesis parts exclude it): the market doesn'"'"'t ask this agent to bid on Soma'"'"'s tasks, and the other host'"'"'s agents, whose nodes build Soma, do them. ~/soma is for reading; if you find a Soma bug or gap, say so in your patch note or reason, starting with "soma:".'; elif governs_soma; then echo 'This network governs Soma too: a task on Soma gives you the market'"'"'s Soma to change, as a task on Pantheon gives you Pantheon; ~/soma is for reading. Keep a Soma patch small, read the tests near what you change, and add a test-suite/misc/soma_*.sh test: CI runs it, and a rejection says what failed.'; else echo 'This network changes Pantheon only; if you find a Soma bug or gap, say so in your patch note or reason, starting with "soma:".'; fi)"; } > "$tmp/instructions.md"
  limactl shell "$v" sh -c 'mkdir -p ~/pantheon && chmod 700 ~/pantheon'
  case $(kind "$a") in
    muse) printf '#!/bin/sh\ncd ~/pantheon && exec ~/.local/bin/muse --yolo "Read ~/pantheon/instructions.md: it is your job. Follow it now."\n' > "$tmp/start.sh" ;;
  esac
  limactl copy "$tmp"/* "$v:pantheon/"; rm -rf "$tmp"
  case $tok in "a new"*) systemctl --user try-restart pantheon-inbox.service 2>/dev/null || true ;; esac
  say "$v is up, with $a's CLI, Soma's source, instructions and $tok"
  say "next: scripts/host.sh login $a (once), then scripts/host.sh diplomats"
}

cmd_login() {
  a=${1:-}; in_vm_agents "$a" || die "usage: scripts/host.sh login AGENT (one of VM_AGENTS: $VM_AGENTS; the others log in on this host: claude, codex, cursor-agent login)"
  case $(kind "$a") in muse) exec limactl shell "$(vm "$a")" sh -c 'exec ~/.local/bin/muse login' ;; esac
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
      case $(kind "$a") in
        muse) herdr pane run "$p" "$(command -v limactl) shell --workdir / $(vm "$a") sh -c 'exec sh \"\$HOME/pantheon/start.sh\"'" >/dev/null ;;
      esac
      say "$a: in its VM, tab \"$a (vm)\""; continue
    fi
    case $(kind "$a") in
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
  printf '== tasks and bids (%s'"'"'s view)\n' "${AGENTS%% *}"; grep -E '^(task|bid) ' "$NET/${AGENTS%% *}/status.txt" 2>/dev/null | cut -c1-160 | tail -12 | sed 's/^/   /' || true
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
  users|services|permissions|network|keygen|join|start|vm|login|diplomats|watchdog|instructions|mirror|check|stop|status|logs) "cmd_$c" "$@" ;;
  mirror-loop) cmd_mirror_loop ;;
  watchdog-loop) cmd_watchdog_loop ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; [ -z "$c" ] || exit 1 ;;
esac
