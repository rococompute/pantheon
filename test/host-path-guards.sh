#!/bin/sh
# Migration preflights must refuse redirected paths before changing any modes
# or accounts. Exercise generated deployment scripts without root or sleeps.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
p="$t/host"
mkdir -p "$t/target"
printf 'private\n' > "$t/target/key.json"
chmod 644 "$t/target/key.json"
for target in net net/codex net/codex/key.json inbox.json; do
  rm -rf "$p"
  mkdir -p "$p/net/claude" "$p/net/codex"
  printf 'first\n' > "$p/net/claude/key.json"
  chmod 755 "$p/net/claude"
  case $target in
    net) rm -rf "$p/net"; ln -s "$t/target" "$p/net" ;;
    net/codex) rmdir "$p/net/codex"; ln -s "$t/target" "$p/net/codex" ;;
    *) ln -s "$t/target/key.json" "$p/$target" ;;
  esac
  HOST_DRY="$t/dry" PANTHEON_HOST="$p" AGENTS='claude codex' BRANCH=master REMOTE= \
    sh "$here/scripts/host.sh" permissions
  sh -n "$t/dry/permissions.sh"
  if sh "$t/dry/permissions.sh" 2> "$t/error"; then exit 1; fi
  grep -q 'symlinked path' "$t/error"
  [ "$(stat -c %a "$t/target/key.json")" = 644 ]
  if [ "$target" != net ]; then
    # Even a later bad path must be found before the first chmod.
    [ "$(stat -c %a "$p/net/claude")" = 755 ]
  fi
  if PANTHEON_HOST="$p" AGENTS='claude codex' BRANCH=master REMOTE= \
    sh "$here/scripts/host.sh" permissions 2>/dev/null; then exit 1; fi
done
HOST_DRY="$t/users" PANTHEON_HOST="$t/unused" HOST_OPERATOR=operator \
 AGENTS='claude codex' BRANCH=master REMOTE= sh "$here/scripts/host.sh" users
# Relocate absolute deployment destinations in the emitted script to fixtures.
# All commands and the guard itself remain the deployment's implementation.
sed -e "s|/var/lib/|$t/lib/|g" -e "s|/etc/sudoers.d/|$t/sudoers/|g" \
  "$t/users/users.sh" > "$t/users-fixture.sh"
mkdir -p "$t/bin" "$t/sudoers"
cat > "$t/bin/action" <<'STUB'
#!/bin/sh
printf '%s\n' "${0##*/}" >> "$LEDGER"
exit 1
STUB
chmod +x "$t/bin/action"
for c in getent useradd chown chmod install groupadd usermod; do ln -s action "$t/bin/$c"; done
for path in pantheon/.ssh pantheon-diplomats/codex pantheon-inbox/codex sudoers; do
  rm -rf "$t/lib"
  mkdir -p "$t/lib/$(dirname "$path")"
  if [ "$path" = sudoers ]; then
    ln -s "$t/target/key.json" "$t/sudoers/pantheon"
  else
    ln -s "$t/target" "$t/lib/$path"
  fi
  : > "$t/ledger"
  if LEDGER="$t/ledger" PATH="$t/bin:$PATH" sh "$t/users-fixture.sh" 2> "$t/error"; then exit 1; fi
  grep -q 'symlinked path' "$t/error"
  [ ! -s "$t/ledger" ]
done
echo PASS
