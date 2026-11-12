#!/bin/sh
# Execute the real emitted provisioning script without root or system writes.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
HOST_DRY="$t/dry" PANTHEON_HOST="$t/unused" AGENTS='claude codex grok' \
  VM_AGENTS=grok HOST_OPERATOR=alice BRANCH=master REMOTE=https://example.invalid/repo \
  sh "$here/scripts/host.sh" credentials
mkdir -p "$t/bin" "$t/root/var/lib/pantheon"
for a in claude codex grok; do
  mkdir -p "$t/root/var/lib/pantheon/net/$a"
  printf 'private %s\n' "$a" > "$t/root/var/lib/pantheon/net/$a/key.json"
done
printf 'private tokens\n' > "$t/root/var/lib/pantheon/inbox.json"
cat > "$t/bin/action" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$LEDGER"
STUB
printf '#!/bin/sh\necho 1000\n' > "$t/bin/id"
chmod +x "$t/bin/action" "$t/bin/id"
for c in chown chmod install runuser systemctl loginctl; do ln -s action "$t/bin/$c"; done
for pass in initial repeat; do
  LEDGER="$t/$pass" HOST_ROOT="$t/root" PATH="$t/bin:$PATH" sh "$t/dry/credentials.sh"
  # Exact expectations, independent of the implementation's enumeration.
  cat > "$t/expected" <<EXPECTED
chown pantheon $t/root/var/lib/pantheon/inbox.json
chmod 0600 $t/root/var/lib/pantheon/inbox.json
chown pantheon $t/root/var/lib/pantheon/net/claude/key.json
chmod 0600 $t/root/var/lib/pantheon/net/claude/key.json
chown pantheon $t/root/var/lib/pantheon/net/codex/key.json
chmod 0600 $t/root/var/lib/pantheon/net/codex/key.json
chown pantheon $t/root/var/lib/pantheon/net/grok/key.json
chmod 0600 $t/root/var/lib/pantheon/net/grok/key.json
EXPECTED
  sed -n '/^chown /p; /^chmod /p' "$t/$pass" > "$t/actual"
  diff -u "$t/expected" "$t/actual"
done
# Missing optional credentials stay absent; provisioning must not create them.
rm "$t/root/var/lib/pantheon/inbox.json"
LEDGER="$t/absent" HOST_ROOT="$t/root" PATH="$t/bin:$PATH" sh "$t/dry/credentials.sh"
! grep -E '^(chown|chmod) .*inbox.json$' "$t/absent"
# A late symlink refuses the entire script before any privileged mutation.
rm "$t/root/var/lib/pantheon/net/grok/key.json"
ln -s "$t/root/var/lib/pantheon/net/codex/key.json" "$t/root/var/lib/pantheon/net/grok/key.json"
: > "$t/refused"
if LEDGER="$t/refused" HOST_ROOT="$t/root" PATH="$t/bin:$PATH" sh "$t/dry/credentials.sh" > "$t/error" 2>&1; then exit 1; fi
[ ! -s "$t/refused" ]
grep -q 'symlinked path' "$t/error"
[ ! -e "$t/unused" ]
echo PASS
