#!/bin/sh
# The users command's sudoers file (P-1): the operator, and only the
# operator, may act as the node and diplomat users. No root, no races.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
# The sudo case: run (as users is run) under sudo, the operator is who
# ran sudo, never the root it defaults to without SUDO_USER.
HOST_DRY="$t/dry" PANTHEON_HOST="$t/unused" AGENTS='claude codex grok muse' \
  SUDO_USER=alice BRANCH=master REMOTE= sh "$here/scripts/host.sh" users
[ ! -e "$t/unused" ]
sh -n "$t/dry/users.sh"
grep -qx "printf \"%s\\\\n\" 'alice ALL=(pantheon,pantheon-claude,pantheon-codex,pantheon-grok,pantheon-muse) NOPASSWD: ALL' > \"\$host_sudo\"" "$t/dry/users.sh"
grep -qx 'install -o root -g root -m 0440 "$host_sudo" /etc/sudoers.d/pantheon' "$t/dry/users.sh"
grep -q 'visudo -cf' "$t/dry/users.sh"
[ "$(grep -c 'NOPASSWD' "$t/dry/users.sh")" = 1 ]
# Installed with the privileged tools stubbed, after the accounts.
mkdir "$t/bin"
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
grep -q '^install <-o> <root> <-g> <root> <-m> <0440>' "$t/ledger"
[ "$(tail -2 "$t/ledger" | head -1 | cut -d' ' -f1)" = install ]
# A root operator by default (sudo from root, or no SUDO_USER naming
# anyone else) is refused before anything is written; naming root on
# purpose is allowed.
if HOST_DRY="$t/badroot" PANTHEON_HOST="$t/unused" AGENTS='claude' \
  SUDO_USER=root BRANCH=master REMOTE= sh "$here/scripts/host.sh" users 2>/dev/null; then exit 1; fi
[ ! -e "$t/badroot/users.sh" ]
HOST_DRY="$t/rootok" PANTHEON_HOST="$t/unused" AGENTS='claude' \
  HOST_OPERATOR=root BRANCH=master REMOTE= sh "$here/scripts/host.sh" users
grep -q "'root ALL=(pantheon,pantheon-claude) NOPASSWD: ALL'" "$t/rootok/users.sh"
# An unsafe operator name is refused before anything is written.
if HOST_DRY="$t/bad" PANTHEON_HOST="$t/unused" AGENTS='claude' \
  HOST_OPERATOR='alice;id' BRANCH=master REMOTE= sh "$here/scripts/host.sh" users 2>/dev/null; then exit 1; fi
[ ! -e "$t/bad/users.sh" ]
echo PASS
