#!/bin/sh
# No operator-account fallback, with initial/partial/repeat provisioning.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
mkdir -p "$t/bin" "$t/host/net" "$t/root/var/lib/pantheon-diplomats"
cat > "$t/bin/herdr" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LEDGER"
case "$1 $2" in
  'tab create') echo '{"result":{"root_pane":{"pane_id":"fixture"}}}' ;;
  *) echo '{}' ;;
esac
STUB
cat > "$t/bin/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SUDOS"
STUB
chmod +x "$t/bin/herdr" "$t/bin/sudo"
export LEDGER="$t/ledger" SUDOS="$t/sudos"
marker="$t/root/var/lib/pantheon-diplomats/sessions"
for provisioned in '' 'claude' 'claude codex' 'claude codex grok'; do
  printf '%s\n' $provisioned > "$marker"
  for attempt in 1 2; do
    : > "$LEDGER"; : > "$SUDOS"
    HOST_ROOT="$t/root" PANTHEON_HOST="$t/host" AGENTS='claude codex grok' \
      HOST_OPERATOR=alice BRANCH=master REMOTE= HERDR_ENV=1 HERDR_WORKSPACE_ID=fixture \
      PATH="$t/bin:$PATH" sh "$here/scripts/host.sh" diplomats > "$t/out"
    for a in claude codex grok; do
      case " $provisioned " in
        *" $a "*)
          grep -qx "pane run fixture exec sudo -iu pantheon-$a" "$LEDGER"
          grep -q "^agent start $a " "$LEDGER"
          ;;
        *)
          grep -q "^host: $a: no isolated session;" "$t/out"
          ! grep -q "^agent start $a " "$LEDGER"
          ! grep -q "pantheon-$a" "$SUDOS"
          ! grep -q -- "--label $a " "$LEDGER"
          ;;
      esac
    done
    [ ! -e "$t/host/desk" ]
    [ ! -e "$t/host/diplomats" ]
    ! grep -q -- '--env PANTHEON_' "$LEDGER"
  done
done
echo 'PASS diplomat startup requires isolated sessions'
