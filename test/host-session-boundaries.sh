#!/bin/sh
# Session preflight against fixed permission views. Execute the deployment's
# emitted script with runuser/install/system tools replaced by ledgers.
# No users, system permissions, real services or timing races.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
HOST_DRY="$t/dry" HOST_OPERATOR=alice PANTHEON_HOST="$t/unused" \
  AGENTS='claude codex grok' BRANCH=master REMOTE= sh "$here/scripts/host.sh" sessions
[ ! -e "$t/unused" ]
sh -n "$t/dry/sessions.sh"
r=$t/root
mkdir -p "$r/etc/systemd/system" "$r/etc/sysctl.d" "$r/var/lib/pantheon"
: > "$r/etc/systemd/system/pantheon-node@.service"
for a in claude codex grok; do
  mkdir -p "$r/var/lib/pantheon-diplomats/$a" "$r/var/lib/pantheon-inbox/$a"
done
mkdir "$t/bin"
cat > "$t/bin/runuser" <<'STUB'
#!/bin/sh
[ "$1" = -u ] && [ "$3" = -- ] || exit 9
who=$2; shift 3
if [ "$1" = test ]; then
  access=$2 target=$3
  printf '%s %s %s\n' "$who" "$access" "$target" >> "$READS"
  if [ "$who" = "${LEAK_USER:-}" ] && [ "$target" = "${LEAK_PATH:-}" ] && [ "$access" = "${LEAK_ACCESS:-}" ]; then exit 0; fi
  case $target in
    /var/lib/pantheon/net/*|/var/lib/pantheon/inbox.json|/var/lib/pantheon/.ssh|/var/lib/pantheon-inbox/*|/var/lib/pantheon-diplomats/*)
      # The clone-exists probe is an ordinary provisioning read.
      [ "$access" = -d ] && exit 0
      exit 1 ;;
    *) exit 0 ;;
  esac
fi
# Record intended writes instead of running anything as a privileged account.
printf 'runuser %s %s\n' "$who" "$1" >> "$MUTATIONS"
STUB
cat > "$t/bin/action" <<'STUB'
#!/bin/sh
printf '%s' "${0##*/}" >> "$MUTATIONS"
for arg do printf ' <%s>' "$arg" >> "$MUTATIONS"; done
printf '\n' >> "$MUTATIONS"
STUB
chmod +x "$t/bin/runuser" "$t/bin/action"
for c in install loginctl sysctl; do ln -s action "$t/bin/$c"; done
export READS="$t/reads" MUTATIONS="$t/mutations"
run() { HOST_ROOT="$r" PATH="$t/bin:$PATH" sh "$t/dry/sessions.sh"; }
: > "$READS"; : > "$MUTATIONS"
run
[ -s "$MUTATIONS" ]
# Every pair is checked for both read and search access to both private roots.
for a in claude codex grok; do
  for b in claude codex grok; do
    for root in pantheon-inbox pantheon-diplomats; do
      for access in -r -x; do
        line="pantheon-$a $access /var/lib/$root/$b"
        if [ "$a" = "$b" ]; then ! grep -qxF "$line" "$READS"; else grep -qxF "$line" "$READS"; fi
      done
    done
  done
  grep -qxF "pantheon-$a -x /var/lib/pantheon/.ssh" "$READS"
  grep -qx "loginctl <enable-linger> <pantheon-$a>" "$MUTATIONS"
done
echo 'ok all three session identities deny both permissions on every other private root'
cp "$READS" "$t/initial-reads"
: > "$READS"; : > "$MUTATIONS"
run
cmp "$READS" "$t/initial-reads"
echo 'ok repeat provisioning reruns every boundary check'
# After safe provisioning, any permission drift must be caught before a write.
# Leak from the last session so earlier successful checks cannot write first.
export LEAK_USER=pantheon-grok
for root in pantheon-inbox pantheon-diplomats; do
  for access in -r -x; do
    export LEAK_PATH="/var/lib/$root/claude" LEAK_ACCESS="$access"
    : > "$READS"; : > "$MUTATIONS"
    if run > "$t/out" 2> "$t/error"; then echo "FAIL accepted $LEAK_PATH $access"; exit 1; fi
    grep -qF 'pantheon-grok can access claude' "$t/error"
    [ ! -s "$MUTATIONS" ]
    echo "ok refuses $access on $root before any write"
  done
done
export LEAK_PATH=/var/lib/pantheon/.ssh LEAK_ACCESS=-x
: > "$READS"; : > "$MUTATIONS"
if run > "$t/out" 2> "$t/error"; then echo 'FAIL accepted search-only push-key directory'; exit 1; fi
grep -qF "pantheon-grok can traverse pantheon's .ssh" "$t/error"
[ ! -s "$MUTATIONS" ]
echo 'ok refuses search-only access to push-key directory before any write'
echo 'PASS session boundaries and repeat provisioning'
