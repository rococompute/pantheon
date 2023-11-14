#!/bin/sh
# The modes step of P-1. Never uses root or a deployed host's directories.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
p="$t/host's private data"
for a in claude codex grok muse; do
  mkdir -p "$p/net/$a"
  printf 'fixture\n' > "$p/net/$a/key.json"
  chmod 755 "$p/net/$a"
  chmod 644 "$p/net/$a/key.json"
done
printf '{}\n' > "$p/inbox.json"
chmod 644 "$p/inbox.json"
HOST_DRY="$t/dry" PANTHEON_HOST="$p" BRANCH=master REMOTE= \
  sh "$here/scripts/host.sh" permissions
# Preview must leave the target untouched.
[ "$(stat -c %a "$p/net/claude")" = 755 ]
[ "$(stat -c %a "$p/inbox.json")" = 644 ]
sh -n "$t/dry/permissions.sh"
sh "$t/dry/permissions.sh"
for a in claude codex grok muse; do
  [ "$(stat -c %a "$p/net/$a")" = 700 ]
  [ "$(stat -c %a "$p/net/$a/key.json")" = 600 ]
  [ "$(cat "$p/net/$a/key.json")" = fixture ]
done
[ "$(stat -c %a "$p/inbox.json")" = 600 ]
# The live command uses the same actions and is safe to repeat.
PANTHEON_HOST="$p" BRANCH=master REMOTE= sh "$here/scripts/host.sh" permissions
[ "$(stat -c %a "$p/net/muse")" = 700 ]
echo PASS
