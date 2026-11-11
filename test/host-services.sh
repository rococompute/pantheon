#!/bin/sh
# System services as the pantheon user (P-1), exercised on a fixture
# root with privileged tools stubbed: no root, no systemd, no races.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
HOST_DRY="$t/dry" PANTHEON_HOST="$t/unused" AGENTS='claude codex' \
  HOST_OPERATOR=alice BRANCH=master REMOTE= sh "$here/scripts/host.sh" services
[ ! -e "$t/unused" ]
sh -n "$t/dry/services.sh"
grep -q '^User=pantheon$' "$t/dry/services.sh"
grep -q 'Environment=XDG_RUNTIME_DIR=/run/user/$uid' "$t/dry/services.sh"
grep -q '^loginctl enable-linger pantheon$' "$t/dry/services.sh"
grep -q 'systemctl enable --now pantheon-node@claude.service pantheon-node@codex.service' "$t/dry/services.sh"
# Per-node files arrive over runuser's stdin (root reads its own 0700
# stage, pantheon writes its own files): no install ever asks the
# installing user to read a path inside that stage.
if grep -q 'runuser -u pantheon -- install .*"\$stage' "$t/dry/services.sh"; then exit 1; fi
grep -q 'runuser -u pantheon -- sh -c' "$t/dry/services.sh"
grep -q '< "$stage/run-claude.sh"' "$t/dry/services.sh"
# What the units execute is checked reachable as pantheon, up front.
grep -q 'runuser -u pantheon -- test -x' "$t/dry/services.sh"
first_write=$(grep -n -e '^install ' -e '^runuser ' "$t/dry/services.sh" | head -1 | cut -d: -f1)
first_guard=$(grep -n '^refuse_link "$R/var/lib/pantheon/net/claude/key.json"$' "$t/dry/services.sh" | cut -d: -f1)
[ "$first_guard" -lt "$first_write" ]
for a in claude codex; do mkdir -p "$t/root/var/lib/pantheon/net/$a"; echo key > "$t/root/var/lib/pantheon/net/$a/key.json"; done
mkdir "$t/bin"
cat > "$t/bin/action" <<'STUB'
#!/bin/sh
printf '%s' "${0##*/}" >> "$LEDGER"
for arg do printf ' <%s>' "$arg" >> "$LEDGER"; done
printf '\n' >> "$LEDGER"
STUB
chmod +x "$t/bin/action"
for c in install runuser systemctl loginctl; do ln -s action "$t/bin/$c"; done
printf '#!/bin/sh\necho 1000\n' > "$t/bin/id"
chmod +x "$t/bin/id"
LEDGER="$t/ledger" HOST_ROOT="$t/root" PATH="$t/bin:$PATH" sh "$t/dry/services.sh"
grep -q '^loginctl <enable-linger> <pantheon>$' "$t/ledger"
grep -q '^runuser <-u> <pantheon> <-->' "$t/ledger"
grep -q 'systemctl <enable> <--now>' "$t/ledger"
grep -q 'systemctl> <--user> <disable> <--now>' "$t/ledger"
# A symlinked key is refused before any privileged write is logged.
rm "$t/root/var/lib/pantheon/net/claude/key.json"; ln -s /etc/passwd "$t/root/var/lib/pantheon/net/claude/key.json"
: > "$t/ledger"
if LEDGER="$t/ledger" HOST_ROOT="$t/root" PATH="$t/bin:$PATH" sh "$t/dry/services.sh" 2>/dev/null; then exit 1; fi
if grep -q -e '^install ' -e '^runuser ' -e '^systemctl ' "$t/ledger"; then exit 1; fi
rm "$t/root/var/lib/pantheon/net/claude/key.json"; echo key > "$t/root/var/lib/pantheon/net/claude/key.json"
rm -rf "$t/root/var/lib/pantheon/net/codex"
if LEDGER="$t/ledger" HOST_ROOT="$t/root" PATH="$t/bin:$PATH" sh "$t/dry/services.sh" 2>/dev/null; then exit 1; fi
echo PASS
