#!/bin/sh
# A whole Pantheon network on one small Linux host, with the agents as
# diplomats: four nodes as systemd services, and beside them, in herdr, one
# interactive session per agent that works its node's inbox. The machine is
# small and shared, so the diplomats only think, answer and judge here; real
# coding work goes to each agent's own workers on its provider's machines
# (Claude Code cloud sessions, Codex Cloud tasks, Cursor Cloud Agents), which
# start from the market's head on GitHub and hand back a branch. An agent
# whose provider has no machines of its own (Muse) gets a VM on this host
# instead, and works its inbox from in there, over HTTP on the host's
# localhost. CI runs one check at a time, in a sandbox (deploy/host/ci-sandbox).
# Nothing listens beyond localhost.
#
# Who runs what (docs/SECURITY-REVIEW-2.md P-1). The diplomats run with their
# approvals off, so none of them is the user that holds a key:
#   pantheon        (NODE_USER) the nodes, the mirror and the inbox server, as
#                   system services. Owns the node keys (each node's home is
#                   0700), the inbox server's tokens and the GitHub push key.
#   pantheon-AGENT  each diplomat on this host (claude, codex, grok): its CLI's
#                   login, its desk, a read-only key for GitHub. Shares only its
#                   inbox with the node user (group inbox-AGENT), and reads the
#                   node user's Soma and Pantheon builds.
#   you             (the operator) run this script, the watchdog and herdr, and
#                   can act as any of them through sudo.
#
#   scripts/host.sh users [--deploy-keys]  once, with sudo: the users, groups, inboxes, keys, and the node user's
#                                      Soma and Pantheon builds (--deploy-keys: add the keys to REMOTE with gh)
#   scripts/host.sh migrate            once, on a host that ran everything as you: the network moves to the node user
#   scripts/host.sh network            keys, the network and its genesis (once), for Pantheon at HEAD
#   scripts/host.sh start              deploy this checkout's HEAD to the node user, write the services and (re)start them
#   scripts/host.sh vm AGENT           AGENT's VM (Muse's): made and started, the agent's CLI in it, a token
#   scripts/host.sh login AGENT        log AGENT's CLI in, as its own user (or in its VM)
#   scripts/host.sh diplomats          from a herdr pane: a tab per agent, each session started as its own user
#   scripts/host.sh watchdog [--check] (re)start the watchdog (--check: what it sees, nudging no one): it nudges an agent whose session stopped working its inbox
#   scripts/host.sh instructions       write each diplomat's instructions again (after changing them; restarts nothing)
#   scripts/host.sh mirror             push the market's head to GitHub now (the mirror service does it every 30s)
#   scripts/host.sh check DIR          the nodes' CI on a checkout, in the sandbox (pantheon-inbox check uses it)
#   scripts/host.sh stop               stop the nodes, the mirror and the inbox server (VMs: limactl stop)
#   scripts/host.sh status             each node's chain, limits, inbox, and the services
#   scripts/host.sh logs [AGENT]       follow a node's log (or the mirror's and the inbox server's)
#
# The node user's home (default /var/lib/pantheon, 0711): net/ (the nodes'
# homes, 0700), repos/ (their checkouts of the governed repositories, which a
# patch checkout shares objects with), soma/ and pantheon/ (its builds),
# inbox.json (the inbox server's tokens, as hashes), goal.txt, publish/.
# The inboxes are in /var/lib/pantheon-inbox/AGENT. A diplomat's home has
# desk/ (its working directory) and instructions.md. Yours, PANTHEON_HOST
# (default ~/pantheon), keeps host.env, goal.txt (copied to the node user at
# start), soma/ (Soma's checkout the node user's build comes from) and the
# watchdog's state.
#
# Settings, from the environment:
#   VM_AGENTS     the agents that work from a VM on this host (default: muse)
#   REMOTE        the GitHub repository workers share (default: this checkout's origin)
#   CODEX_ENV     the Codex Cloud environment for codex's workers (codex cloud lists them)
#   GROK_MODEL    the Cursor CLI's model for grok (default: grok; cursor-agent models lists them)
#   SOMA_REMOTE   Soma's repository, for the agents to read (default: https://github.com/yevbar/soma.git)
#   BRANCH        the branch of REMOTE the market publishes to and workers start from (default: its default branch)
#   SOMA_REF      the branch there at the commit SOMA_DIR is built from (default: gradual, Soma's default branch)
#   SOMA_DIR      your Soma checkout, the source of the node user's build (default: PANTHEON_HOST/soma)
#   NODE_USER     the node user (default: pantheon), NODE_HOME its home for users to make (default: /var/lib/pantheon)
#   HOST_SKIP_CLIS  1: users installs no agent CLIs for the diplomats' users
# or from PANTHEON_HOST/host.env (lines like CODEX_ENV=soma), read first.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
P=${PANTHEON_HOST:-$HOME/pantheon}
[ ! -f "$P/host.env" ] || . "$P/host.env"
AGENTS="claude codex grok muse"
VM_AGENTS=${VM_AGENTS:-muse}
NODE_USER=${NODE_USER:-pantheon}
case $NODE_USER in ''|*[!a-z0-9_-]*) printf 'host: NODE_USER must be a plain user name\n' >&2; exit 1 ;; esac
NH=$(getent passwd "$NODE_USER" 2>/dev/null | cut -d: -f6 || true)
NET=$NH/net REPOS=$NH/repos NSRC=$NH/pantheon NSOMA=$NH/soma
BIN=$NSRC/main.exe
SOMA_SRC=${SOMA_DIR:-$P/soma}
INBOXES=/var/lib/pantheon-inbox
BUILD_LOCK=/var/lib/pantheon-build/lock
CI_MEMORY=${CI_MEMORY:-1536m}
PANTHEON_CI=${PANTHEON_CI:-timeout 120 soma build main.soma && timeout 120 test/edits.sh && sh test/ci-policy.sh && timeout 120 bash test/cli.sh && timeout 120 bash test/genesis.sh && timeout 120 bash test/double-bid.sh && timeout 120 sh test/soma-misc-runner.sh && timeout 120 sh test/host-quoting.sh}
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
UNITS=/etc/systemd/system
export PATH="$HOME/.local/bin:$PATH"
say() { printf 'host: %s\n' "$*"; }
die() { printf 'host: %s\n' "$*" >&2; exit 1; }
in_vm_agents() { case " $VM_AGENTS " in *" $1 "*) return 0 ;; esac; return 1; }
is_agent() { case " $AGENTS " in *" $1 "*) return 0 ;; esac; return 1; }
diplomat_agents() { for a in $AGENTS; do in_vm_agents "$a" || printf '%s ' "$a"; done; }
vm() { printf 'pantheon-%s' "$1"; }
duser() { printf 'pantheon-%s' "$1"; }
dhome() { getent passwd "$(duser "$1")" | cut -d: -f6; }
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# as the node user, or a diplomat's: through sudo, as users set it up
as_node() { if [ "$(id -un)" = "$NODE_USER" ]; then "$@"; else sudo -n -u "$NODE_USER" -H "$@"; fi; }
as_dip() { u=$(duser "$1"); shift; if [ "$(id -un)" = "$u" ]; then "$@"; else sudo -n -u "$u" -H "$@"; fi; }
need_users() {
  [ -n "$NH" ] || die "no node user $NODE_USER yet: run scripts/host.sh users (once, with sudo)"
  for a in $(diplomat_agents); do id "$(duser "$a")" >/dev/null 2>&1 || die "no user $(duser "$a") for $a's diplomat: run scripts/host.sh users"; done
  as_node true 2>/dev/null || die "can't act as $NODE_USER through sudo without a password: run scripts/host.sh users, which allows it"
}
need_bin() { need_users; as_node test -x "$BIN" || die "no $BIN: run scripts/host.sh users (it builds Soma and Pantheon as $NODE_USER), or scripts/host.sh start"; }
soma_commit() { as_node cat "$NSOMA/.commit" 2>/dev/null || echo unknown; }
ci_cmd() { as_node python3 "$NSRC/deploy/ci-command.py" "$NSRC" "$PANTHEON_CI"; }
github_repo() { printf '%s' "$1" | sed -n 's#^\(git@github\.com:\|ssh://git@github\.com/\|https://github\.com/\)\([^/]*/[^/]*\)$#\2#p' | sed 's/\.git$//'; }

# The users, groups, inboxes and builds. Run once, and again after adding an
# agent; it skips what's there. Everything that needs root is in one sudo.
cmd_users() {
  keys=""; [ "${1:-}" = --deploy-keys ] && keys=1
  case $(id -un) in root|"$NODE_USER") die "run this as yourself, the operator, not as $(id -un): it uses sudo for what needs root" ;; esac
  dips=$(diplomat_agents)
  say "users $NODE_USER and $(for a in $dips; do printf '%s ' "$(duser "$a")"; done)and the inboxes (sudo)"
  sudo sh -s "$NODE_USER" "${NODE_HOME:-/var/lib/pantheon}" "$(id -un)" "$INBOXES" "$BUILD_LOCK" "$dips" "$VM_AGENTS" <<'ROOT'
set -eu
node=$1 nhome=$2 op=$3 inboxes=$4 lock=$5 dips=$6 vms=$7
id "$node" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$nhome" --shell /bin/bash "$node"
nhome=$(getent passwd "$node" | cut -d: -f6)
# traversable, not listable: its builds are the diplomats' to read; net/ isn't
chmod 711 "$nhome"
for a in $dips; do
  u=pantheon-$a
  id "$u" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$u"
  chmod 700 "$(getent passwd "$u" | cut -d: -f6)"
done
install -d -m 755 "$inboxes"
for a in $dips $vms; do
  g=inbox-$a
  getent group "$g" >/dev/null || groupadd "$g"
  usermod -aG "$g" "$node"
  case " $dips " in *" $a "*) usermod -aG "$g" "pantheon-$a" ;; esac
  install -d -o "$node" -g "$g" -m 2770 "$inboxes/$a"
done
# one CI build at a time on the host, the nodes' and the diplomats' checks
install -d -m 755 "${lock%/*}"; [ -e "$lock" ] || install -m 644 /dev/null "$lock"
# opam takes locks even to list a switch: a diplomat's own soma build in its
# desk shares those with the node user, through opamshare
getent group opamshare >/dev/null || groupadd opamshare
usermod -aG opamshare "$node"; for a in $dips; do usermod -aG opamshare "pantheon-$a"; done
# you act as any of them; the node user lets its diplomats' files in a patch
# checkout go (bidder-inbox.sh's chmod, as the diplomat)
others=$node; for a in $dips; do others="$others,pantheon-$a"; done
f=/etc/sudoers.d/pantheon-host
{ printf '%s ALL=(%s) NOPASSWD: ALL\n' "$op" "$others"
  [ -z "$dips" ] || printf '%s ALL=(%s) NOPASSWD: %s\n' "$node" "${others#"$node",}" "$(command -v chmod)"; } > "$f.new"
chmod 440 "$f.new"; visudo -cqf "$f.new" && mv "$f.new" "$f"
# ci-sandbox runs a check in a systemd user scope: each user that runs CI
# needs its user manager running
loginctl enable-linger "$node"; for a in $dips; do loginctl enable-linger "pantheon-$a"; done
# a diplomat's session runs in a pane of your terminal: with TIOCSTI it could
# type into it as you
if [ -e /proc/sys/dev/tty/legacy_tiocsti ]; then
  echo 'dev.tty.legacy_tiocsti = 0' > /etc/sysctl.d/60-pantheon-tiocsti.conf
  sysctl -q -w dev.tty.legacy_tiocsti=0
fi
ROOT
  NH=$(getent passwd "$NODE_USER" | cut -d: -f6); NET=$NH/net REPOS=$NH/repos NSRC=$NH/pantheon NSOMA=$NH/soma BIN=$NSRC/main.exe
  # keys: the node user's pushes (the mirror), each diplomat's only reads
  gh_repo=$(github_repo "$REMOTE")
  key() {
    who=$1 title=$2 write=$3; shift 3
    "$@" sh -c 'mkdir -p -m 700 ~/.ssh && { [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C "$1" -f ~/.ssh/id_ed25519; } \
      && { grep -qs "^github.com " ~/.ssh/known_hosts || ssh-keyscan -t ed25519 github.com 2>/dev/null >> ~/.ssh/known_hosts; }' sh "$title"
    pub=$("$@" cat .ssh/id_ed25519.pub)
    if [ -n "$keys" ] && [ -n "$gh_repo" ]; then
      printf '%s\n' "$pub" | gh repo deploy-key add - --repo "$gh_repo" --title "$title" $write >/dev/null 2>&1 \
        && say "$who: its key is a deploy key on $gh_repo${write:+, with write access}" \
        || say "$who: adding its key to $gh_repo failed (gh logged in, with admin on it? or it's there already)"
    else
      say "$who's key, for $gh_repo${write:+ with write access}: $pub"
    fi
  }
  key "$NODE_USER (the mirror)" "pantheon-host-mirror" --allow-write as_node env -C "$NH"
  for a in $dips; do key "$(duser "$a")" "pantheon-host-$a" "" as_dip "$a" env -C "$(dhome "$a")"; done
  [ -n "$keys" ] || say "add them as deploy keys (the mirror's with write access, the others read-only), or run this again with --deploy-keys"
  cmd_build
  [ "${HOST_SKIP_CLIS:-}" = 1 ] || for a in $dips; do install_cli "$a"; done
  say "next: scripts/host.sh migrate (if this host ran everything as you), or network; then start, login AGENT for each diplomat, diplomats"
}

# an agent's CLI, in its diplomat's home: the same installers the sandbox uses
install_cli() {
  a=$1
  case $a in
    claude) as_dip "$a" sh -c 'test -x ~/.local/bin/claude || curl -fsSL https://claude.ai/install.sh | bash' >/dev/null ;;
    codex)  as_dip "$a" sh -c 'test -x ~/.local/bin/codex || npm install -g -s --prefix ~/.local @openai/codex' >/dev/null ;;
    grok)   as_dip "$a" sh -c 'test -x ~/.local/bin/cursor-agent || curl -fsS https://cursor.com/install | bash' >/dev/null ;;
    *) return 0 ;;
  esac || { say "$a: installing its CLI as $(duser "$a") failed: install it in that user's ~/.local/bin by hand"; return 0; }
  say "$a: its CLI is installed for $(duser "$a")"
}

# Soma (once) and Pantheon (each start), built by the node user: it can't read
# your home, so the source goes to it through a pipe
cmd_build() {
  need_users
  if ! as_node test -x "$NSOMA/_build/install/default/bin/soma"; then
    [ -d "$SOMA_SRC/.git" ] || die "no Soma checkout at $SOMA_SRC: set SOMA_DIR to one (git clone $SOMA_REMOTE)"
    c=$(git -C "$SOMA_SRC" rev-parse HEAD)
    say "building Soma $(echo "$c" | cut -c1-10) as $NODE_USER (the first time: a while)"
    git -C "$SOMA_SRC" archive --format=tar "$c" | as_node sh -c 'rm -rf /tmp/pantheon-soma-src && mkdir /tmp/pantheon-soma-src && tar -x -C /tmp/pantheon-soma-src'
    deploy_pantheon nobuild
    as_node sh -c 'cd "$1" && SOMA_REPO=/tmp/pantheon-soma-src SOMA_DIR="$2" SOMA_ONLY=1 sh scripts/setup-node.sh && echo "$3" > "$2/.commit"' sh "$NSRC" "$NSOMA" "$c" \
      || die "building Soma as $NODE_USER failed: see above"
    as_node rm -rf /tmp/pantheon-soma-src
  fi
  deploy_pantheon
  # for the diplomats' checks and builds: read-only
  as_node sh -c 'chmod -R a+rX "$1" "$2/.opam" "$2/.cache" 2>/dev/null; mkdir -p "$2/.opam/log"; chgrp opamshare "$2/.opam/log" && chmod 2775 "$2/.opam/log"
    find "$2/.opam" "$2/.cache/soma" -maxdepth 5 \( -name lock -o -name "*.lock" \) -exec chgrp opamshare {} + -exec chmod g+w {} + 2>/dev/null; true' sh "$NSOMA" "$NH"
}

# this checkout's HEAD, as a git clone the node user owns (the network's
# genesis names it), built unless "nobuild"
deploy_pantheon() {
  [ -z "$(git -C "$here" status --porcelain --untracked-files=no)" ] \
    || say "note: $here has changes not committed; the nodes get its HEAD, $(git -C "$here" rev-parse --short HEAD)"
  t=$(mktemp -d); chmod 755 "$t"
  git -C "$here" bundle create -q "$t/p.bundle" HEAD 2>/dev/null || git -C "$here" bundle create "$t/p.bundle" HEAD >/dev/null 2>&1
  chmod 644 "$t/p.bundle"
  as_node sh -c '
    set -e; d=$1
    rm -rf "$d.new"; git clone -q "$2" "$d.new"; git -C "$d.new" checkout -q --detach HEAD
    if [ "$3" != nobuild ]; then
      (cd "$d.new" && PATH="$4/_build/install/default/bin:$PATH" soma build main.soma >/dev/null) \
        || { echo "host: building Pantheon as $(id -un) failed: soma build main.soma in $d.new" >&2; exit 1; }
    fi
    rm -rf "$d.old"; [ ! -d "$d" ] || mv "$d" "$d.old"; mv "$d.new" "$d"; rm -rf "$d.old"; chmod -R a+rX "$d"' \
    sh "$NSRC" "$t/p.bundle" "${1:-build}" "$NSOMA" || { rm -rf "$t"; die "deploying Pantheon to $NODE_USER failed"; }
  rm -rf "$t"
  say "$NODE_USER has Pantheon at $(git -C "$here" log -1 --format='%h %s')"
}

cmd_network() {
  need_bin
  as_node test ! -e "$NET" || die "$NET already holds a network. A new chain is a new network: stop it, move $NET away (as $NODE_USER), and run this again"
  # the cloud run's parameters (examples/network/network.json): an hour's
  # term, attest window and stuck-task limit; fallback after 15 minutes
  as_node sh -c 'umask 077 && "$1" init "$2" --repo "pantheon=$3" --base-port 26701 --block-ms 1000 \
    --param term_blocks=3600 --param max_merges=2 --param stall_blocks=1800 --param attest_window=3600 \
    --param fallback_blocks=900 --param reveal_window=30 --param bid_cooldown=5 && chmod 700 "$2" "$2"/*' sh "$BIN" "$NET" "$NSRC"
  [ -f "$P/goal.txt" ] || { mkdir -p "$P"; cp "$here/examples/cloud/goal.txt" "$P/goal.txt"; }
  say "a network for Pantheon at $(as_node git -C "$NSRC" log -1 --format='%h %s'); goals in $P/goal.txt"
  say "next: scripts/host.sh start, then scripts/host.sh vm muse, then scripts/host.sh diplomats (from a herdr pane)"
}

# From a host that ran everything as you (net/, inbox.json and goal.txt in
# PANTHEON_HOST): the network moves to the node user, chain and keys included,
# and your copy is renamed for you to delete once the nodes run.
cmd_migrate() {
  need_users
  [ -d "$P/net" ] || die "nothing to migrate: no $P/net"
  as_node test ! -e "$NET" || die "$NET is there already: the node user has a network"
  say "stopping the services you ran as yourself"
  systemctl --user disable --now pantheon-mirror.service pantheon-inbox.service \
    $(for a in $AGENTS; do printf 'pantheon-node@%s.service ' "$a"; done) 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/pantheon-node@.service" "$HOME/.config/systemd/user/pantheon-mirror.service" "$HOME/.config/systemd/user/pantheon-inbox.service"
  systemctl --user daemon-reload 2>/dev/null || true
  tar -C "$P" -cf - net | as_node sh -c 'set -e; umask 077; mkdir -p "$1"; tar -x -C "$1"; chmod 700 "$1/net" "$1/net"/*
    mkdir -p "$1/repos"; chmod 755 "$1/repos"
    for h in "$1/net"/*; do a=${h##*/}; [ ! -d "$h/repos" ] || { rm -rf "$1/repos/$a"; mv "$h/repos" "$1/repos/$a"; }; done
    chmod -R a+rX "$1/repos"' sh "$NH"
  if [ -f "$P/inbox.json" ]; then
    # the tokens stay; each agent's inbox is the shared one now
    python3 - "$P/inbox.json" "$INBOXES" <<'PY' | as_node sh -c 'umask 077 && cat > "$1"' sh "$NH/inbox.json"
import json, sys
c = json.load(open(sys.argv[1]))
for a, v in c.get("agents", {}).items():
    if isinstance(v, dict) and "inbox" in v: v["inbox"] = sys.argv[2] + "/" + a
print(json.dumps(c))
PY
  fi
  stamp=$(date +%Y%m%d-%H%M%S)
  mv "$P/net" "$P/net.migrated-$stamp"; [ ! -f "$P/inbox.json" ] || mv "$P/inbox.json" "$P/inbox.json.migrated-$stamp"
  say "the network is $NODE_USER's now, in $NET. Your old copy is $P/net.migrated-$stamp: it holds the node keys, so delete it once the nodes run (rm -rf)"
  say "next: scripts/host.sh start, then scripts/host.sh login AGENT for each diplomat (its CLI logs in again, as its own user)"
}

# the instructions a diplomat on this host follows, for its provider, in its home
render_diplomat() {
  a=$1; h=$(dhome "$a"); desk=$h/desk
  as_dip "$a" mkdir -p "$desk"
  # a plain clone of the shared repository: cloud hand-offs start from the
  # GitHub remote and branch of the directory they run in
  [ -z "$REMOTE" ] || as_dip "$a" test -d "$desk/pantheon/.git" || as_dip "$a" git clone -q "$REMOTE" "$desk/pantheon" \
    || say "$a: can't clone $REMOTE into $desk/pantheon as $(duser "$a") (its read key: scripts/host.sh users): its cloud hand-offs need it"
  # some agent CLIs (codex) give their commands only a few of their own
  # environment variables: the inbox's settings go in a wrapper instead.
  # Every value quoted: REMOTE and BRANCH come from the remote (P-11)
  { printf '#!/bin/sh\n'
    printf 'PANTHEON_INBOX=%s PANTHEON_REMOTE=%s PANTHEON_BRANCH=%s PANTHEON_CHECK=%s \\\n' \
      "$(q "$INBOXES/$a")" "$(q "$REMOTE")" "$(q "$BRANCH")" "$(q "$NSRC/scripts/host.sh check")"
    printf '  exec %s "$@"\n' "$(q "$NSRC/scripts/pantheon-inbox")"; } | as_dip "$a" sh -c 'cat > "$1" && chmod 755 "$1"' sh "$desk/pantheon-inbox"
  d=$NSRC/deploy/host/delegate/$a.md
  # the values reach Python through its environment, never its source
  R_AGENT=$a R_REMOTE=$REMOTE R_BRANCH=$BRANCH R_NET=$NET R_CODEX_ENV=${CODEX_ENV:-ENV_ID} R_DESK=$desk \
  R_SOMA_REMOTE=$SOMA_REMOTE R_SOMA_REF=$SOMA_REF R_SOMA_DIR=$NSOMA R_SOMA_COMMIT=$(soma_commit) \
  R_SOMA_NOTES=$h/soma-notes.md R_GROK_MODEL=$GROK_MODEL \
  python3 - "$NSRC/deploy/host/diplomat.md" "$d" <<'PY' | as_dip "$a" sh -c 'cat > "$1"' sh "$h/instructions.md"
import sys, os
t = open(sys.argv[1]).read()
d = open(sys.argv[2]).read() if os.path.exists(sys.argv[2]) else "## How you hand off\n\nYou have no workers elsewhere: do patches by hand, small, and skip what's too big."
t = t.replace("{{DELEGATE}}", d.strip())
# the inbox command by its full path: the wrapper with this agent's settings
t = t.replace("pantheon-inbox ", "{{DESK}}/pantheon-inbox ").replace("`pantheon-inbox`", "`{{DESK}}/pantheon-inbox`")
for k in ["AGENT", "REMOTE", "BRANCH", "NET", "CODEX_ENV", "DESK", "SOMA_REMOTE", "SOMA_REF",
          "SOMA_DIR", "SOMA_COMMIT", "SOMA_NOTES", "GROK_MODEL"]:
    t = t.replace("{{%s}}" % k, os.environ["R_" + k])
sys.stdout.write(t)
PY
}

# a system service, written through sudo
unit() { sudo sh -c 'cat > "$1.new" && mv "$1.new" "$1"' sh "$UNITS/$1"; }

cmd_start() {
  need_users
  as_node test -d "$NET" || die "no network yet: scripts/host.sh network (or migrate)"
  cmd_build
  ci=$(ci_cmd)
  uid=$(id -u "$NODE_USER")
  [ -f "$P/goal.txt" ] || { mkdir -p "$P"; cp "$here/examples/cloud/goal.txt" "$P/goal.txt"; }
  as_node sh -c 'cat > "$1"' sh "$NH/goal.txt" < "$P/goal.txt"
  for a in $AGENTS; do
    # the node strips PANTHEON_* from a backend's environment: the backend sets
    # its own. BIDDER_USER is the diplomat's user, whose files in a patch
    # checkout bidder-inbox.sh lets go of
    if in_vm_agents "$a"; then url="INBOX_URL=http://$VM_HOST:$PORT "; bu=""; else url=""; bu="BIDDER_USER=$(duser "$a") "; fi
    printf '#!/bin/sh\nPANTHEON_INBOX=%s %s%sexec %s\n' "$(q "$INBOXES/$a")" "$url" "$bu" "$(q "$NSRC/scripts/bidder-inbox.sh")" \
      | as_node sh -c 'cat > "$1" && chmod 755 "$1"' sh "$NET/$a/backend.sh"
    { printf '#!/bin/sh\n'
      printf 'PANTHEON_REPOS=%s exec %s node %s --backend cmd:%s --goal %s --listen 127.0.0.1 \\\n' \
        "$(q "$REPOS/$a")" "$(q "$BIN")" "$(q "$NET/$a")" "$(q "$NET/$a/backend.sh")" "$(q "$NH/goal.txt")"
      printf '  --ci-repo pantheon %s --ci-sandbox %s --ci-memory %s\n' "$(q "$ci")" "$(q "$NSRC/deploy/host/ci-sandbox")" "$CI_MEMORY"; } \
      | as_node sh -c 'cat > "$1" && chmod 755 "$1"' sh "$NET/$a/run.sh"
    as_node sh -c 'mkdir -p "$1" && chmod 755 "$1" "${1%/*}"' sh "$REPOS/$a"
    in_vm_agents "$a" || render_diplomat "$a"
  done
  unit pantheon-node@.service <<U
[Unit]
Description=Pantheon node %i
After=network.target user@$uid.service
Wants=user@$uid.service
[Service]
User=$NODE_USER
Environment=SOMA_DIR=$NSOMA
Environment=CI_LOCK=$BUILD_LOCK
Environment=XDG_RUNTIME_DIR=/run/user/$uid
Environment=PATH=$NSOMA/_build/install/default/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$NET/%i/run.sh
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
U
  # the market's head on GitHub, where the agents' workers start from
  unit pantheon-mirror.service <<U
[Unit]
Description=Pantheon's merged head, pushed to $REMOTE as $BRANCH
After=network-online.target
[Service]
User=$NODE_USER
Environment=REMOTE=$REMOTE
Environment=BRANCH=$BRANCH
ExecStart=$NSRC/scripts/host.sh mirror-loop
Restart=on-failure
RestartSec=60
[Install]
WantedBy=multi-user.target
U
  units=""
  [ -n "$REMOTE" ] && units="pantheon-mirror.service" || say "no REMOTE (this checkout has no origin): workers elsewhere can't see the market's head"
  if [ -n "$VM_AGENTS" ]; then
    # for the VMs: on the host's localhost, which a VM reaches and nothing outside does
    as_node sh -c '[ -f "$1" ] || { umask 077; printf "{\"listen\": \"127.0.0.1:%s\", \"url\": \"\", \"agents\": {}}\n" "$2" > "$1"; }' sh "$NH/inbox.json" "$PORT"
    unit pantheon-inbox.service <<U
[Unit]
Description=Pantheon inbox over HTTP, for the agents' VMs
[Service]
User=$NODE_USER
ExecStart=/usr/bin/python3 $NSRC/scripts/inbox-http.py serve $NH/inbox.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
U
    units="$units pantheon-inbox.service"
  fi
  for a in $AGENTS; do units="$units pantheon-node@$a.service"; done
  sudo systemctl daemon-reload
  # every node at once: restarting them one by one mid-height stalls the chain
  sudo systemctl enable -q $units
  sudo systemctl restart $units
  if command -v herdr >/dev/null; then write_watchdog_unit; systemctl --user daemon-reload; systemctl --user enable -q --now pantheon-watchdog.service; units="$units pantheon-watchdog.service (yours)"; fi
  say "started: $units"
  say "next: scripts/host.sh diplomats, from a herdr pane; watch it: scripts/host.sh status"
}

# the market's head (any node's: merges commit the same way on every node),
# published to BRANCH: a fast-forward, or a merge when people committed there
# too (scripts/publish.sh). As the node user: its key pushes
cmd_mirror() {
  [ -n "$REMOTE" ] || die "no REMOTE: set it to the GitHub repository workers share"
  r=$REPOS/claude/pantheon
  as_node test -d "$r" || die "no network yet: scripts/host.sh network"
  as_node env QUIET="${quiet:-}" PUBLISH_DIR="$NH/publish" "$NSRC/scripts/publish.sh" "$r" "$REMOTE" "$BRANCH"
}
cmd_mirror_loop() { while :; do quiet=1 cmd_mirror || true; sleep 30; done; }

# The watchdog. An agent's session sometimes ends its turn (a summary, as if
# the job were done) while its node keeps sending requests: nothing answers
# them until someone looks. Every minute this looks at each agent's session in
# herdr; one idle two checks running gets a nudge back to its loop, and again
# every five minutes while it stays idle. An agent whose node holds requests
# for a usage limit is left alone (it's right to stop), and so is one blocked
# on a question (that needs a person). It's yours: herdr is.
write_watchdog_unit() {
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/pantheon-watchdog.service" <<U
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

node_status() { as_node cat "$NET/$1/status.txt" 2>/dev/null; }

watch_agent() {
  a=$1 st=$P/watchdog; mkdir -p "$st"
  if node_status "$a" | grep -q '^LIMIT'; then rm -f "$st/$a"; return 0; fi
  if in_vm_agents "$a"; then
    # while Muse runs a command or thinks, its screen says "esc to interrupt"
    p=$(vm_pane "$a") || return 0
    if herdr pane read "$p" --source visible 2>/dev/null | grep -q "esc to interrupt"; then idle=0; else idle=1; fi
    file="~/pantheon/instructions.md"
  else
    case $(herdr agent list 2>/dev/null | jq -r --arg a "$a" '.result.agents[] | select(.name == $a) | .agent_status') in
      idle|done) idle=1 ;; *) idle=0 ;;   # working, blocked (a person's call), or no session
    esac
    file=$(dhome "$a")/instructions.md
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
  need_users
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
    git -C "$SOMA_SRC" archive --format=tar HEAD | limactl shell "$v" sh -c 'mkdir -p ~/soma && tar -x -C ~/soma'
  fi
  limactl shell "$v" sh -c 'command -v git >/dev/null && command -v jq >/dev/null || { sudo apt-get update -q && sudo apt-get install -y -q git jq curl; }' >/dev/null
  # a token for this agent's inbox only; the instructions, the token beside them
  as_node sh -c '[ -f "$1" ] || { umask 077; printf "{\"listen\": \"127.0.0.1:%s\", \"url\": \"\", \"agents\": {}}\n" "$2" > "$1"; }' sh "$NH/inbox.json" "$PORT"
  tmp=$(mktemp -d); umask 077
  # a token once; NEW_TOKEN=1 replaces it (a running session then loses its inbox)
  if [ -n "${NEW_TOKEN:-}" ] || ! limactl shell "$v" test -s pantheon/token 2>/dev/null; then
    as_node python3 "$NSRC/scripts/inbox-http.py" token "$NH/inbox.json" "$a" "$INBOXES/$a" > "$tmp/token"; tok="a new token (the old one, if any, no longer works)"
  else tok="its token as it was"; fi
  { sed -e "s|{{AGENT}}|$a|g" -e "s|{{URL}}|http://$VM_HOST:$PORT|g" "$here/deploy/cloud/agent.md"
    printf '\nYour token is in the file ~/pantheon/token: send it as -H "Authorization: Bearer $(cat ~/pantheon/token)". This VM is your machine: work in it as you like.\n'
    printf '\n## Soma, the language Pantheon is written in\n\nSoma is a fork of the Rocq Prover with gradual dependent types, and its source is its documentation: ~/soma is the commit the network builds with (%s; not built here). Start with README.md, GRADUAL.md, gradual-coverage.md, vision.md and examples/; test-suite/ and theories/ show how a feature behaves. When a task leans on a Soma feature, look it up there instead of guessing from Rocq you remember: this fork differs. This network changes Pantheon only; if you find a Soma bug or gap, say so in your patch note or reason, starting with "soma:".\n' "$(soma_commit)"; } > "$tmp/instructions.md"
  limactl shell "$v" sh -c 'mkdir -p ~/pantheon && chmod 700 ~/pantheon'
  case $a in
    muse) printf '#!/bin/sh\ncd ~/pantheon && exec ~/.local/bin/muse --yolo "Read ~/pantheon/instructions.md: it is your job. Follow it now."\n' > "$tmp/start.sh" ;;
  esac
  limactl copy "$tmp"/* "$v:pantheon/"; rm -rf "$tmp"
  case $tok in "a new"*) sudo systemctl try-restart pantheon-inbox.service 2>/dev/null || true ;; esac
  say "$v is up, with $a's CLI, Soma's source, instructions and $tok"
  say "next: scripts/host.sh login $a (once), then scripts/host.sh diplomats"
}

# log a diplomat's CLI in as its own user (its login lives in that user's home)
cmd_login() {
  a=${1:-}; is_agent "$a" || die "usage: scripts/host.sh login AGENT (one of $AGENTS)"
  if in_vm_agents "$a"; then
    case $a in muse) exec limactl shell "$(vm "$a")" sh -c 'exec ~/.local/bin/muse login' ;; esac
  fi
  need_users
  u=$(duser "$a")
  case $a in
    claude) say "Claude Code starts as $u: log in with /login, then /exit"; exec sudo -iu "$u" claude ;;
    codex)  exec sudo -iu "$u" codex login --device-auth ;;
    grok)   exec sudo -iu "$u" cursor-agent login ;;
  esac
}

# start: AGENT KIND EXECUTABLE ARGS..., in a herdr tab of its own, as its own
# user: the tab's shell becomes that user's, and herdr starts the agent there
cmd_diplomats() {
  command -v herdr >/dev/null || die "no herdr: install it (herdr.dev)"
  [ "${HERDR_ENV:-}" = 1 ] || die "run this from a pane in herdr (start herdr on this host, then run it there)"
  need_users
  as_node test -d "$NET" || die "no network yet: scripts/host.sh network, then start"
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
    u=$(duser "$a")
    as_dip "$a" sh -c "command -v $exe >/dev/null || test -x ~/.local/bin/$exe" \
      || { say "$a: no $exe for $u: scripts/host.sh users installs it, then scripts/host.sh login $a"; continue; }
    render_diplomat "$a"
    p=$(herdr tab create --workspace "$ws" --label "$a" --cwd "$P" --no-focus | jq -r .result.root_pane.pane_id)
    # the pane's shell is the diplomat's, in its desk, with its CLI on the PATH
    herdr pane run "$p" "exec sudo -iu $u sh -c 'cd ~/desk && PATH=\$HOME/.local/bin:\$PATH exec bash -i'" >/dev/null
    sleep 3
    # shellcheck disable=SC2086
    herdr agent start "$a" --kind "$kind" --pane "$p" --timeout 60000 -- $args >/dev/null \
      || { say "$a: $exe didn't come up ready as $u (logged in? scripts/host.sh login $a; herdr pane read $p)"; continue; }
    herdr agent prompt "$a" "Read $(dhome "$a")/instructions.md: it is your job, as $a's diplomat in a Pantheon network. Follow it now." >/dev/null
    say "$a: started in tab \"$a\", as $u"
  done
  say "in this workspace ($ws): a tab per agent, and one for status"
}

cmd_instructions() {
  need_users
  for a in $(diplomat_agents); do render_diplomat "$a"; say "$a: $(dhome "$a")/instructions.md"; done
  [ -z "$VM_AGENTS" ] || say "the VMs' instructions: scripts/host.sh vm AGENT"
}

# as whoever asks (a diplomat, through pantheon-inbox check): the node user's
# Soma and switch, read-only, and the host's one CI lock
cmd_check() {
  d=${1:-}; [ -d "$d" ] || die "usage: scripts/host.sh check DIR (a checkout of Pantheon)"
  [ -n "$NH" ] || die "no node user $NODE_USER: the host isn't set up (scripts/host.sh users)"
  ci=$(python3 "$NSRC/deploy/ci-command.py" "$NSRC" "$PANTHEON_CI")
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} SOMA_DIR=$NSOMA CI_OPAMROOT=$NH/.opam CI_SWITCH=$NH/.cache/soma/ocaml CI_LOCK=$BUILD_LOCK \
    exec "$NSRC/deploy/host/ci-sandbox" "$CI_MEMORY" "$d" "$ci"
}

cmd_stop() {
  sudo systemctl stop pantheon-mirror.service pantheon-inbox.service $(for a in $AGENTS; do printf 'pantheon-node@%s ' "$a"; done) 2>/dev/null
  systemctl --user stop pantheon-watchdog.service 2>/dev/null; say "stopped"
}

cmd_status() {
  need_users
  for a in $AGENTS; do
    printf '== %s (%s)\n' "$a" "$(systemctl is-active "pantheon-node@$a" 2>/dev/null || true)"
    node_status "$a" | sed -n '1,3p' | sed 's/^/   /'
    node_status "$a" | grep -h '^LIMIT' | sed 's/^/   /' || true
    n=$(as_node ls "$INBOXES/$a" 2>/dev/null | grep -c '^[0-9]*-' || true); [ "$n" = 0 ] || printf '   inbox: %s waiting\n' "$n"
  done
  printf '== tasks and bids (claude'"'"'s view)\n'; node_status claude | grep -E '^(task|bid) ' | cut -c1-160 | tail -12 | sed 's/^/   /' || true
  printf '== services: mirror %s, inbox %s, watchdog %s; VMs: %s\n' "$(systemctl is-active pantheon-mirror 2>/dev/null || true)" \
    "$(systemctl is-active pantheon-inbox 2>/dev/null || true)" "$(systemctl --user is-active pantheon-watchdog 2>/dev/null || true)" \
    "$(for a in $VM_AGENTS; do printf '%s %s ' "$(vm "$a")" "$(limactl list --format '{{.Status}}' "$(vm "$a")" 2>/dev/null || echo none)"; done)"
  journalctl -u pantheon-mirror -n 1 -o cat 2>/dev/null | grep -q 'mirror:' && printf '   %s\n' "$(journalctl -u pantheon-mirror -n 1 -o cat | cut -c1-200)"
  printf '== memory: %s\n' "$(free -m | awk '/^Mem/ {print $7 " MB available of " $2}')"
}

cmd_logs() {
  case ${1:-} in
    '') exec journalctl -f -u pantheon-mirror -u pantheon-inbox ;;
    *) exec journalctl -f -u "pantheon-node@$1" ;;
  esac
}

c=${1:-}; [ $# -gt 0 ] && shift
case $c in
  users|migrate|build|network|start|vm|login|diplomats|watchdog|instructions|mirror|check|stop|status|logs) "cmd_$c" "$@" ;;
  mirror-loop) cmd_mirror_loop ;;
  watchdog-loop) cmd_watchdog_loop ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; [ -z "$c" ] || exit 1 ;;
esac
