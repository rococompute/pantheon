#!/bin/sh
# Rootless execution of the production provisioning script, twice.
# Capture the actual staged units installed by root, without system changes.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
HOST_DRY="$t/dry" PANTHEON_HOST="$t/unused" AGENTS='claude codex grok' \
  VM_AGENTS=grok HOST_OPERATOR=alice BRANCH=master REMOTE=https://example.invalid/repo \
  sh "$here/scripts/host.sh" services
mkdir -p "$t/bin" "$t/units"
for a in claude codex grok; do
  mkdir -p "$t/root/var/lib/pantheon/net/$a"
done
cat > "$t/bin/install" <<'STUB'
#!/bin/sh
# Only copy the staged service files; record every privileged operation.
printf 'install %s\n' "$*" >> "$LEDGER"
for arg do
  case $arg in
    */pantheon-*.service)
      if [ -f "$arg" ]; then cp "$arg" "$CAPTURE/${arg##*/}"; fi ;;
  esac
done
STUB
cat > "$t/bin/action" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$LEDGER"
STUB
printf '#!/bin/sh\necho 1000\n' > "$t/bin/id"
chmod +x "$t/bin/install" "$t/bin/action" "$t/bin/id"
for c in runuser systemctl loginctl; do ln -s action "$t/bin/$c"; done
for pass in initial repeat; do
  LEDGER="$t/$pass" CAPTURE="$t/units" HOST_ROOT="$t/root" PATH="$t/bin:$PATH" \
    sh "$t/dry/services.sh"
  for unit in pantheon-node@ pantheon-mirror pantheon-inbox; do
    f="$t/units/$unit.service"
    [ "$(grep -c '^User=pantheon$' "$f")" = 1 ]
    [ "$(grep -c '^UMask=0077$' "$f")" = 1 ]
  done
  grep -qx 'systemctl enable --now pantheon-node@claude.service pantheon-node@codex.service pantheon-node@grok.service pantheon-mirror.service pantheon-inbox.service' "$t/$pass"
done
[ ! -e "$t/unused" ]
echo PASS
