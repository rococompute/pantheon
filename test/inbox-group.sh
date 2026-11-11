#!/bin/sh
# Rootless coverage of the group-sharing step of P-1.
set -eu
cd "$(dirname "$0")/.."
t=$(mktemp -d)
pid=
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf "$t"' EXIT HUP INT TERM
mkdir "$t/inbox" "$t/checkout" "$t/checkout.git"
printf 'node metadata\n' > "$t/checkout.git/config"
chmod 700 "$t/checkout.git"
chmod 600 "$t/checkout.git/config"
printf 'patch\n' > "$t/checkout/file"
chmod 777 "$t/checkout" "$t/checkout/file"
PANTHEON_INBOX="$t/inbox" PANTHEON_WORKTREE="$t/checkout" \
 PANTHEON_INBOX_GROUP="$(id -gn)" sh scripts/bidder-inbox.sh \
 </dev/null > "$t/out" &
pid=$!
r=
for i in $(seq 1 100); do
  for candidate in "$t"/inbox/*; do
    if [ -f "$candidate/prompt.txt" ]; then r=$candidate; break; fi
  done
  [ -z "$r" ] || break
  sleep .05
done
[ -n "$r" ]
[ "$(stat -c %a "$r")" = 2770 ]
[ "$(stat -c %a "$r/prompt.txt")" = 660 ]
[ "$(stat -c %a "$t/checkout")" = 2770 ]
[ "$(stat -c %a "$t/checkout/file")" = 770 ]
[ "$(stat -c %a "$t/checkout.git")" = 700 ]
[ "$(stat -c %a "$t/checkout.git/config")" = 600 ]
[ "$(stat -c %G "$t/checkout/file")" = "$(id -gn)" ]
printf '{"ok":true}\n' > "$r/reply.txt"
wait "$pid"
pid=
grep -qx '{"ok":true}' "$t/out"
[ ! -d "$r" ]
# Group mode does not broaden permissions again on exit.
[ "$(stat -c %a "$t/checkout/file")" = 770 ]
# A bad group must not publish a request or fall back to world access.
PANTHEON_INBOX="$t/inbox" PANTHEON_WORKTREE="$t/checkout" \
 PANTHEON_INBOX_GROUP=pantheon-nonexistent-test-group \
 sh scripts/bidder-inbox.sh </dev/null > "$t/out" 2>/dev/null
grep -q "can't share inbox group" "$t/out"
[ -z "$(ls -A "$t/inbox")" ]
# Refuse a symlink before recursively changing any target's permissions.
ln -s "$t/checkout.git/config" "$t/checkout/link"
PANTHEON_INBOX="$t/inbox" PANTHEON_WORKTREE="$t/checkout" \
 PANTHEON_INBOX_GROUP="$(id -gn)" \
 sh scripts/bidder-inbox.sh </dev/null > "$t/out"
grep -q "containing symlinks" "$t/out"
[ "$(stat -c %a "$t/checkout.git/config")" = 600 ]
[ -z "$(ls -A "$t/inbox")" ]
echo PASS
