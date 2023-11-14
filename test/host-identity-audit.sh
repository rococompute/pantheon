#!/bin/sh
# Execute the real emitted provisioning script against NSS fixtures and an
# action ledger. No users, groups, ownership or host permissions are changed.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
HOST_DRY="$t/dry" HOST_OPERATOR=alice PANTHEON_HOST="$t/unused" \
  AGENTS='claude codex' BRANCH=master REMOTE= sh "$here/scripts/host.sh" users
[ ! -e "$t/unused" ]
sh -n "$t/dry/users.sh"
mkdir "$t/bin"
cat > "$t/bin/getent" <<'STUB'
#!/usr/bin/env python3
import os, sys
path = os.environ['NSS_PASSWD' if sys.argv[1] == 'passwd' else 'NSS_GROUP']
rows = open(path).read().splitlines()
if len(sys.argv) > 2:
    key = sys.argv[2]
    rows = [r for r in rows if r.split(':')[0] == key or r.split(':')[2] == key]
if not rows: sys.exit(2)
print('\n'.join(rows))
STUB
cat > "$t/bin/id" <<'STUB'
#!/usr/bin/env python3
import os, sys
assert sys.argv[1] == '-nG'
for row in open(os.environ['NSS_MEMBERSHIPS']):
    name, groups = row.rstrip('\n').split(':', 1)
    if name == sys.argv[2]:
        print(groups)
        sys.exit(0)
sys.exit(1)
STUB
cat > "$t/bin/action" <<'STUB'
#!/bin/sh
printf '%s' "${0##*/}" >> "$LEDGER"
for arg do printf ' <%s>' "$arg" >> "$LEDGER"; done
printf '\n' >> "$LEDGER"
STUB
chmod +x "$t/bin/getent" "$t/bin/id" "$t/bin/action"
for c in useradd groupadd usermod chown chmod install visudo; do ln -s action "$t/bin/$c"; done
export NSS_PASSWD="$t/passwd" NSS_GROUP="$t/group" NSS_MEMBERSHIPS="$t/memberships" LEDGER="$t/ledger"
fixture() {
  cat > "$NSS_PASSWD" <<'DATA'
pantheon:x:1100:1100::/var/lib/pantheon:/bin/sh
pantheon-claude:x:1101:1101::/var/lib/pantheon-diplomats/claude:/bin/sh
pantheon-codex:x:1102:1102::/var/lib/pantheon-diplomats/codex:/bin/sh
DATA
  cat > "$NSS_GROUP" <<'DATA'
pantheon:x:1100:
pantheon-claude:x:1101:
pantheon-codex:x:1102:
inbox-claude:x:1201:pantheon,pantheon-claude
inbox-codex:x:1202:pantheon,pantheon-codex
DATA
  cat > "$NSS_MEMBERSHIPS" <<'DATA'
pantheon-claude:pantheon-claude inbox-claude
pantheon-codex:pantheon-codex inbox-codex
DATA
}
run_script() { PATH="$t/bin:$PATH" sh "$t/dry/users.sh"; }
refuses() {
  : > "$LEDGER"
  if run_script > "$t/out" 2> "$t/error"; then echo "FAIL accepted $1"; exit 1; fi
  grep -q "$2" "$t/error"
  [ ! -s "$LEDGER" ] || { echo "FAIL mutated before refusing $1"; cat "$LEDGER"; exit 1; }
  echo "ok refuses $1 before any provisioning mutation"
}
# Initial provisioning goes through the same code, with no existing records.
: > "$NSS_PASSWD"; : > "$NSS_GROUP"; : > "$NSS_MEMBERSHIPS"; : > "$LEDGER"
run_script
[ "$(grep -c '^useradd ' "$LEDGER")" -eq 3 ]
for a in claude codex; do
  grep -qx "chmod <0700> </var/lib/pantheon-diplomats/$a>" "$LEDGER"
  grep -qx "install <-d> <-o> <pantheon> <-g> <inbox-$a> <-m> <2770> </var/lib/pantheon-inbox/$a>" "$LEDGER"
done
echo 'ok initial multi-diplomat provisioning and inbox permissions'
fixture; : > "$LEDGER"; run_script
! grep -q '^useradd ' "$LEDGER"
! grep -q '^groupadd ' "$LEDGER"
[ "$(grep -c '^usermod ' "$LEDGER")" -eq 4 ]
echo 'ok safe repeat provisioning keeps accounts and restores modes'
# A safe primary member is permitted even if absent from the member list.
fixture
sed 's/pantheon-claude:x:1101:1101:/pantheon-claude:x:1101:1201:/' "$NSS_PASSWD" > "$t/new"
mv "$t/new" "$NSS_PASSWD"
: > "$LEDGER"; run_script
echo 'ok assigned diplomat may use its inbox as primary group'
fixture
printf 'pantheon-codex:pantheon-codex inbox-codex inbox-claude\n' > "$NSS_MEMBERSHIPS"
# Keep the earlier account valid so this exercises a late failure.
printf 'pantheon-claude:pantheon-claude inbox-claude\n' >> "$NSS_MEMBERSHIPS"
refuses 'cross-inbox membership' 'unrelated group inbox-claude'
for privileged in sudo docker; do
  fixture
  printf 'pantheon-codex:pantheon-codex inbox-codex %s\n' "$privileged" >> "$NSS_MEMBERSHIPS.tmp"
  sed '/^pantheon-codex:/d' "$NSS_MEMBERSHIPS" >> "$NSS_MEMBERSHIPS.tmp"
  mv "$NSS_MEMBERSHIPS.tmp" "$NSS_MEMBERSHIPS"
  refuses "privileged $privileged membership" "unrelated group $privileged"
done
fixture
sed 's|/var/lib/pantheon-diplomats/codex|/other|' "$NSS_PASSWD" > "$t/new"; mv "$t/new" "$NSS_PASSWD"
refuses 'unexpected late home' 'unexpected home'
fixture
sed 's/pantheon-codex:x:1102:/pantheon-codex:x:0:/' "$NSS_PASSWD" > "$t/new"; mv "$t/new" "$NSS_PASSWD"
refuses 'root identity' 'unsafe uid'
fixture
printf 'other:x:1102:1300::/other:/bin/sh\n' >> "$NSS_PASSWD"
refuses 'UID alias' 'shares its uid'
fixture
sed 's/inbox-codex:x:1202:pantheon,pantheon-codex/inbox-codex:x:1202:pantheon,pantheon-codex,other/' "$NSS_GROUP" > "$t/new"; mv "$t/new" "$NSS_GROUP"
refuses 'unrelated supplementary inbox member' 'admits unrelated account other'
fixture
printf 'other:x:1300:1202::/other:/bin/sh\n' >> "$NSS_PASSWD"
refuses 'unlisted primary inbox member' 'admits unrelated account other'
fixture
printf 'other-group:x:1202:\n' >> "$NSS_GROUP"
refuses 'inbox GID alias' 'shares its gid'
fixture
sed 's/inbox-codex:x:1202:/inbox-codex:x:0:/' "$NSS_GROUP" > "$t/new"; mv "$t/new" "$NSS_GROUP"
refuses 'root inbox group' 'unsafe gid'
# No provisioning path may put a diplomat in the node user's private group.
fixture; : > "$LEDGER"; run_script
! grep -q 'usermod .*<-G> <pantheon> <pantheon-' "$LEDGER"
echo 'PASS isolated identity audit (initial, repeat, denied cross-account access)'
