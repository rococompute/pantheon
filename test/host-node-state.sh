#!/bin/sh
# Rootless execution of the same ownership migration emitted for deployment.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
HOST_DRY="$t/dry" PANTHEON_HOST="$t/unused" AGENTS='claude codex grok' \
  VM_AGENTS=grok HOST_OPERATOR=alice BRANCH=master REMOTE=https://example.invalid/repo \
  sh "$here/scripts/host.sh" node-state
mkdir -p "$t/bin"
for a in claude codex grok; do
  h=$t/root/var/lib/pantheon/net/$a
  mkdir -p "$h/repos/..calc/.git/objects"
  printf state > "$h/consensus.state"
  printf log > "$h/signed.log"
  printf object > "$h/repos/..calc/.git/objects/example"
done
cat > "$t/bin/action" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$LEDGER"
STUB
chmod +x "$t/bin/action"
ln -s action "$t/bin/chown"
ln -s action "$t/bin/chmod"
for pass in initial repeat; do
  LEDGER="$t/$pass" HOST_ROOT="$t/root" PATH="$t/bin:$PATH" sh "$t/dry/node-state.sh"
  cat > "$t/expected" <<EXPECTED
chown -R pantheon $t/root/var/lib/pantheon/net/claude
chmod 0700 $t/root/var/lib/pantheon/net/claude
chown -R pantheon $t/root/var/lib/pantheon/net/codex
chmod 0700 $t/root/var/lib/pantheon/net/codex
chown -R pantheon $t/root/var/lib/pantheon/net/grok
chmod 0700 $t/root/var/lib/pantheon/net/grok
EXPECTED
  diff -u "$t/expected" "$t/$pass"
done
refused() {
  : > "$t/ledger"
  if LEDGER="$t/ledger" HOST_ROOT="$t/root" PATH="$t/bin:$PATH" sh "$t/dry/node-state.sh" > "$t/error" 2>&1; then
    echo 'unsafe migration accepted' >&2; exit 1
  fi
  [ ! -s "$t/ledger" ]
}
# A link hidden deep in the last agent must fail before adopting the first.
h=$t/root/var/lib/pantheon/net/grok
ln -s "$t/outside" "$h/repos/..calc/.git/objects/link"
refused
grep -q 'symlink in node home' "$t/error"
rm "$h/repos/..calc/.git/objects/link"
printf private > "$t/outside"
ln "$t/outside" "$h/alias"
refused
grep -q 'hardlinked file' "$t/error"
rm "$h/alias"
mv "$h" "$t/grok"
ln -s "$t/grok" "$h"
refused
grep -q 'symlinked path' "$t/error"
rm "$h"
refused
grep -q 'missing node home' "$t/error"
[ ! -e "$t/unused" ]
echo PASS
