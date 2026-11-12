#!/bin/sh
# Run the real emitted preflight without root; no privileged tool may be
# reached when an ancestor redirects a deployment write, even on repeat.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
mkdir -p "$t/bin" "$t/target"
cat > "$t/bin/action" <<'STUB'
#!/bin/sh
printf '%s\n' "${0##*/}" >> "$LEDGER"
exit 1
STUB
chmod +x "$t/bin/action"
for c in runuser install systemctl loginctl chown chmod sysctl; do
  ln -s action "$t/bin/$c"
done
for command in services sessions; do
  HOST_DRY="$t/dry" PANTHEON_HOST="$t/unused" HOST_OPERATOR=alice \
    AGENTS='claude codex grok' VM_AGENTS=muse BRANCH=master REMOTE= \
    sh "$here/scripts/host.sh" "$command"
  sh -n "$t/dry/$command.sh"
  case $command in
    services) paths='var var/lib var/lib/pantheon/net var/lib/pantheon/.ssh etc/systemd/system' ;;
    sessions) paths='var var/lib var/lib/pantheon-diplomats var/lib/pantheon-inbox etc/sysctl.d' ;;
  esac
  for path in $paths; do
    rm -rf "$t/root"
    mkdir -p "$t/root/var/lib/pantheon/net" "$t/root/etc/systemd/system" \
      "$t/root/etc/sysctl.d" "$t/root/var/lib/pantheon-diplomats" \
      "$t/root/var/lib/pantheon-inbox"
    for a in claude codex grok; do
      mkdir -p "$t/root/var/lib/pantheon/net/$a" \
        "$t/root/var/lib/pantheon-diplomats/$a" "$t/root/var/lib/pantheon-inbox/$a"
    done
    : > "$t/root/etc/systemd/system/pantheon-node@.service"
    rm -rf "$t/root/$path"
    ln -s "$t/target" "$t/root/$path"
    for attempt in first repeat; do
      : > "$t/ledger"
      if HOST_ROOT="$t/root" LEDGER="$t/ledger" PATH="$t/bin:$PATH" \
        sh "$t/dry/$command.sh" 2> "$t/error"; then
        echo "accepted $command $path ($attempt)" >&2; exit 1
      fi
      grep -q 'symlinked path' "$t/error"
      [ ! -s "$t/ledger" ]
      [ -z "$(ls -A "$t/target")" ]
    done
  done
done
printf 'PASS\n'
