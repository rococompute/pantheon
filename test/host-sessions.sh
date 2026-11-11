#!/bin/sh
# Diplomat sessions as their own users (P-1): the sessions command's root
# script, run on a fixture root with the privileged tools stubbed (no root,
# no systemd, no races), and the diplomats command's live path with herdr
# and sudo stubbed. Checks the users, the modes and the paths each user
# gets, that no diplomat file names a secret, and the refusals.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
fail() { echo "FAIL: $*"; exit 1; }
git init -q --bare "$t/remote.git"
HOST_DRY="$t/dry" PANTHEON_HOST="$t/unused" AGENTS='claude codex muse' HOST_OPERATOR=alice \
  BRANCH=master REMOTE="$t/remote.git" sh "$here/scripts/host.sh" sessions
[ ! -e "$t/unused" ] || fail "a dry run wrote outside its directory"
s=$t/dry/sessions.sh
sh -n "$s"
# only the host's sessions: muse works from its VM
if grep -q 'pantheon-muse' "$s"; then fail "muse, a VM agent, got a session user"; fi
grep -q '^put pantheon-claude "$R"'"'/var/lib/pantheon-diplomats/claude/instructions.md' 0600" "$s" || fail "no instructions for claude"
grep -q '^loginctl enable-linger pantheon-codex$' "$s" || fail "no linger for codex's check"
# root never writes in a diplomat's home: the diplomat does, over stdin
if grep -q '^install .*pantheon-diplomats/claude' "$s"; then fail "root installs into claude's home"; fi
# every check before the first write, and the marker the live path reads last
last_check=$(grep -n -e '|| refuse' -e 'then refuse' "$s" | tail -1 | cut -d: -f1)
first_write=$(grep -n -e '^put ' -e '^install ' -e '^loginctl ' -e '^runuser -u [a-z-]* -- sh -c' -e '^runuser -u [a-z-]* -- mkdir' "$s" | head -1 | cut -d: -f1)
[ "$last_check" -lt "$first_write" ] || fail "a write ($first_write) before the last check ($last_check)"
tail -1 "$s" | grep -q "/var/lib/pantheon-diplomats/sessions'$" || fail "the sessions marker isn't written last"

# The fixture: what users and services leave behind.
r=$t/root
mkdir -p "$r/etc/systemd/system" "$r/etc/sysctl.d" "$r/var/lib/pantheon/net/claude" "$r/var/lib/pantheon/net/codex"
: > "$r/etc/systemd/system/pantheon-node@.service"
for a in claude codex; do mkdir -p "$r/var/lib/pantheon-diplomats/$a" "$r/var/lib/pantheon-inbox/$a"; done
mkdir "$t/bin"
# runuser runs the command as the caller, telling a stubbed test whose view it is
cat > "$t/bin/runuser" <<'STUB'
#!/bin/sh
printf 'runuser %s\n' "$*" >> "$LEDGER"
[ "$1" = -u ] && [ "$3" = -- ] || exit 9
RUNAS=$2; export RUNAS; shift 3
exec "$@"
STUB
# a diplomat's view: no secret is readable (unless LEAK), pantheon's builds are
cat > "$t/bin/test" <<'STUB'
#!/bin/sh
for p do
  case $p in
    /var/lib/pantheon/net/*|/var/lib/pantheon/inbox.json|/var/lib/pantheon/.ssh) [ -n "${LEAK:-}" ]; exit $? ;;
    /var/lib/pantheon/soma/*|/var/lib/pantheon/.opam|/var/lib/pantheon/.cache/*) exit 0 ;;
  esac
done
exec sh -c 'test "$@"' sh "$@"
STUB
# install without -o/-g (not root), logged
cat > "$t/bin/install" <<'STUB'
#!/bin/sh
printf 'install %s\n' "$*" >> "$LEDGER"
n=$#; skip=
for a do
  if [ -n "$skip" ]; then skip=; continue; fi
  case $a in -o|-g) skip=1; continue ;; esac
  set -- "$@" "$a"
done
shift "$n"
exec /usr/bin/env -i PATH=/usr/bin:/bin install "$@"
STUB
cat > "$t/bin/log" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$LEDGER"
STUB
for c in loginctl sysctl; do ln -s log "$t/bin/$c"; done
chmod +x "$t/bin/runuser" "$t/bin/test" "$t/bin/install" "$t/bin/log"
# run [LEAK]: LEAK makes every secret readable to the diplomats
run() { LEAK=${1:-} LEDGER="$t/ledger" HOST_ROOT="$r" PATH="$t/bin:$PATH" sh "$s"; }
wrote() { grep -q -e '^install ' -e '^loginctl ' -e ' -- sh -c ' -e ' -- mkdir ' "$t/ledger"; }

# Refusals first, each before any write.
rm "$r/etc/systemd/system/pantheon-node@.service"; : > "$t/ledger"
if run 2>/dev/null; then fail "sessions ran before services"; fi
if wrote; then fail "a write before services was found missing"; fi
: > "$r/etc/systemd/system/pantheon-node@.service"; : > "$t/ledger"
if run 1 2>/dev/null; then fail "sessions ran with a key a diplomat can read"; fi
if wrote; then fail "a write before the readable key was refused"; fi
mv "$r/var/lib/pantheon-diplomats/codex" "$t/codex-home"; ln -s "$t/codex-home" "$r/var/lib/pantheon-diplomats/codex"; : > "$t/ledger"
if run 2>/dev/null; then fail "sessions followed a symlinked home"; fi
if wrote; then fail "a write before the symlinked home was refused"; fi
rm "$r/var/lib/pantheon-diplomats/codex"; mv "$t/codex-home" "$r/var/lib/pantheon-diplomats/codex"

: > "$t/ledger"
run
mode() { stat -c %a "$r$1"; }
for a in claude codex; do
  h=/var/lib/pantheon-diplomats/$a
  [ "$(mode "$h/instructions.md")" = 600 ] || fail "$a's instructions are $(mode "$h/instructions.md")"
  [ "$(mode "$h/.profile")" = 600 ] || fail "$a's .profile mode"
  [ "$(mode "$h/desk")" = 700 ] || fail "$a's desk mode"
  [ "$(mode "$h/desk/pantheon-inbox")" = 700 ] || fail "$a's inbox wrapper mode"
  [ "$(mode "$h/desk/pantheon-check")" = 700 ] || fail "$a's check wrapper mode"
  [ -d "$r$h/desk/pantheon/.git" ] || fail "$a has no clone of the remote"
  # written by the diplomat itself
  grep -q "^runuser -u pantheon-$a -- sh -c .* $r$h/desk/pantheon-inbox 0700\$" "$t/ledger" || fail "$a's wrapper wasn't written as pantheon-$a"
  grep -q "PANTHEON_INBOX='/var/lib/pantheon-inbox/$a' " "$r$h/desk/pantheon-inbox" || fail "$a's wrapper doesn't name its inbox"
  grep -q "PANTHEON_CHECK='$h/desk/pantheon-check' " "$r$h/desk/pantheon-inbox" || fail "$a's wrapper doesn't name its check"
  sh -n "$r$h/desk/pantheon-inbox"; sh -n "$r$h/desk/pantheon-check"; sh -n "$r$h/.profile"
  for v in "SOMA_DIR='/var/lib/pantheon/soma'" "CI_OPAMROOT='/var/lib/pantheon/.opam'" "CI_LOCK='/var/lib/pantheon/.ci-lock'" "/deploy/host/ci-sandbox'"; do
    grep -qF "$v" "$r$h/desk/pantheon-check" || fail "$a's check lacks $v"
  done
  grep -qF "$h/desk/pantheon-inbox wait" "$r$h/instructions.md" || fail "$a's instructions don't name its wrapper"
  # its only path to the nodes is its inbox: no secret, no other inbox, nothing of the operator's
  for f in desk/pantheon-inbox desk/pantheon-check .profile; do
    if grep -q -e key.json -e inbox.json -e '\.ssh' -e '/var/lib/pantheon/net' -e "$t/unused" "$r$h/$f"; then fail "$a's $f names a secret or the operator's tree"; fi
  done
  for b in claude codex; do
    [ "$b" = "$a" ] && continue
    if grep -rq "pantheon-inbox/$b" "$r$h/desk/pantheon-inbox" "$r$h/desk/pantheon-check" "$r$h/.profile"; then fail "$a's files name $b's inbox"; fi
  done
  grep -q "^loginctl enable-linger pantheon-$a\$" "$t/ledger" || fail "no linger for $a"
  grep -q "^runuser -u pantheon-$a -- test -r /var/lib/pantheon/net/claude/key.json\$" "$t/ledger" || fail "$a wasn't checked for claude's key"
done
[ ! -e "$r/var/lib/pantheon-diplomats/muse" ] || fail "muse got a home"
[ "$(mode /var/lib/pantheon/.ci-lock)" = 644 ] || fail "the CI lock mode"
grep -q '^runuser -u pantheon -- sh -c .*/var/lib/pantheon/.ci-lock$' "$t/ledger" || fail "the CI lock isn't pantheon's"
[ "$(mode /var/lib/pantheon-diplomats/sessions)" = 644 ] || fail "the sessions marker mode"
[ "$(cat "$r/var/lib/pantheon-diplomats/sessions")" = "$(printf 'claude\ncodex')" ] || fail "the sessions marker: $(cat "$r/var/lib/pantheon-diplomats/sessions")"
grep -qx 'dev.tty.legacy_tiocsti = 0' "$r/etc/sysctl.d/60-pantheon-tiocsti.conf" || fail "TIOCSTI isn't off"
grep -q '^sysctl -q -w dev.tty.legacy_tiocsti=0$' "$t/ledger" || fail "TIOCSTI isn't set now"
[ "$(tail -1 "$t/ledger" | cut -d' ' -f1)" = install ] || fail "the marker isn't installed last"

# The live path: claude has its own user (the marker), codex doesn't yet.
printf 'claude\n' > "$r/var/lib/pantheon-diplomats/sessions"
mkdir -p "$t/p/net" "$t/live"
cat > "$t/live/herdr" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$HLEDGER"
case "$1 $2" in "tab create") echo '{"result":{"root_pane":{"pane_id":"p1"}}}' ;; *) echo '{}' ;; esac
STUB
cat > "$t/live/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SLEDGER"
[ -z "${SUDO_FAIL:-}" ]
STUB
chmod +x "$t/live/herdr" "$t/live/sudo"
# live [SUDO_FAIL]: SUDO_FAIL makes the diplomat's user find no CLI
live() {
  SUDO_FAIL=${1:-} HLEDGER="$t/hl" SLEDGER="$t/sl" HOST_ROOT="$r" HERDR_ENV=1 HERDR_WORKSPACE_ID=ws PANTHEON_HOST="$t/p" \
    AGENTS='claude codex' VM_AGENTS= HOST_OPERATOR=alice BRANCH=master REMOTE="$t/remote.git" \
    PATH="$t/live:$PATH" sh "$here/scripts/host.sh" diplomats
}
: > "$t/hl"; : > "$t/sl"
live > "$t/out"
grep -qx -- '-n -iu pantheon-claude command -v claude' "$t/sl" || fail "claude's CLI wasn't looked for as pantheon-claude"
if grep -q pantheon-codex "$t/sl" "$t/hl"; then fail "codex, without the marker, ran as its user"; fi
grep -qx 'pane run p1 exec sudo -iu pantheon-claude' "$t/hl" || fail "claude's pane isn't pantheon-claude's login shell"
grep -qx 'agent start claude --kind claude --pane p1 --timeout 60000 -- --dangerously-skip-permissions' "$t/hl" || fail "claude wasn't started with approvals off and the readiness wait"
grep -q '^agent prompt claude Read /var/lib/pantheon-diplomats/claude/instructions.md: ' "$t/hl" || fail "claude wasn't pointed at its own instructions"
# the operator's tree and environment don't reach it
if grep '^tab create .*--label claude' "$t/hl" | grep -q -e '--env' -e "$t/p"; then fail "claude's tab carries the operator's environment"; fi
if grep -q "$t/p/inbox/claude\|$t/p/diplomats/claude" "$t/hl"; then fail "claude was given the operator's inbox or instructions"; fi
[ ! -e "$t/p/diplomats/claude.md" ] || fail "claude's instructions were rendered in the operator's tree"
# no CLI for its user: no session, and it says why
: > "$t/hl"; : > "$t/sl"
live 1 > "$t/out"
if grep -q '^agent start claude' "$t/hl"; then fail "claude started without its CLI"; fi
grep -q 'pantheon-claude has no claude' "$t/out" || fail "no word on claude's missing CLI: $(cat "$t/out")"
echo PASS
