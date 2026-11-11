#!/bin/sh
# Account provisioning can be reviewed and exercised without root or races.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
HOST_DRY="$t/dry" PANTHEON_HOST="$t/unused" AGENTS='claude codex grok muse' \
 BRANCH=master REMOTE= sh "$here/scripts/host.sh" users
[ ! -e "$t/unused" ]
sh -n "$t/dry/users.sh"
mkdir "$t/bin"
# Run the exact deployment script with privileged tools replaced by a ledger.
cat > "$t/bin/action" <<'STUB'
#!/bin/sh
printf '%s' "${0##*/}" >> "$LEDGER"
for arg do printf ' <%s>' "$arg" >> "$LEDGER"; done
printf '\n' >> "$LEDGER"
STUB
chmod +x "$t/bin/action"
for c in useradd groupadd usermod chown chmod install; do ln -s action "$t/bin/$c"; done
printf '#!/bin/sh\nexit 2\n' > "$t/bin/getent"
chmod +x "$t/bin/getent"
LEDGER="$t/ledger" PATH="$t/bin:$PATH" sh "$t/dry/users.sh"
grep -qx 'useradd <--user-group> <--create-home> <--home-dir> </var/lib/pantheon> <--shell> </bin/sh> <pantheon>' "$t/ledger"
grep -qx 'chmod <0711> </var/lib/pantheon>' "$t/ledger"
grep -qx 'install <-d> <-o> <pantheon> <-m> <0700> </var/lib/pantheon/.ssh>' "$t/ledger"
for a in claude codex grok muse; do
  grep -qx "useradd <--user-group> <--create-home> <--home-dir> </var/lib/pantheon-diplomats/$a> <--shell> </bin/sh> <pantheon-$a>" "$t/ledger"
  grep -qx "chmod <0700> </var/lib/pantheon-diplomats/$a>" "$t/ledger"
  grep -qx "usermod <-a> <-G> <inbox-$a> <pantheon-$a>" "$t/ledger"
  grep -qx "usermod <-a> <-G> <inbox-$a> <pantheon>" "$t/ledger"
  grep -qx "install <-d> <-o> <pantheon> <-g> <inbox-$a> <-m> <2770> </var/lib/pantheon-inbox/$a>" "$t/ledger"
done
[ "$(grep -c '^usermod ' "$t/ledger")" = 8 ]
# Names must be validated before emitting any script.
if HOST_DRY="$t/bad" PANTHEON_HOST="$t/unused" AGENTS='codex;id' \
 BRANCH=master REMOTE= sh "$here/scripts/host.sh" users 2>/dev/null; then exit 1; fi
[ ! -e "$t/bad/users.sh" ]
# Existing unrelated accounts fail closed before modifying their homes.
printf '#!/bin/sh\nprintf "pantheon:x:1:1::/other:/bin/sh\\n"\n' > "$t/bin/getent"
: > "$t/ledger"
if LEDGER="$t/ledger" PATH="$t/bin:$PATH" sh "$t/dry/users.sh" 2>/dev/null; then exit 1; fi
[ ! -s "$t/ledger" ]
echo PASS
