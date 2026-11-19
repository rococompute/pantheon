#!/bin/sh
# The node, as pantheon-node.service runs it, listening on this VM's address.
# scripts/sandbox.sh start writes what differs per node, in /etc/pantheon:
#   backend      the --backend
#   ci/REPO      REPO's CI command, run in pantheon:dev by pantheon-ci
#   ci-memory    a CI container's memory and /tmp
#   flags        more node flags, one word per line
#   goal.txt     the goal lines
set -eu
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# Ask the kernel for the selected IPv4 route; interface names vary across
# Lima, cloud and user-created VMs. An absent address must never mean bind-all.
route=$(ip -4 -o route get 1.1.1.1) || { echo "node: no usable IPv4 route" >&2; exit 3; }
ip=$(printf '%s\n' "$route" | awk '{for (i=1; i<NF; i++) if ($i == "src") {print $(i+1); exit}}')
case "$ip" in ''|*[!0-9.]*) echo "node: no IPv4 source address on the default route" >&2; exit 3 ;; esac
set -- --backend "$(cat /etc/pantheon/backend)" --goal /etc/pantheon/goal.txt --listen "$ip" \
  --ci-image pantheon:dev --ci-memory "$(cat /etc/pantheon/ci-memory)"
for f in /etc/pantheon/ci/*; do
  [ -f "$f" ] && set -- "$@" --ci-repo "$(basename "$f")" "pantheon-ci $(q "$(cat "$f")")"
done
if [ -f /etc/pantheon/flags ]; then
  while IFS= read -r w; do [ -n "$w" ] && set -- "$@" "$w"; done < /etc/pantheon/flags
fi
exec /home/pantheon/pantheon/main.exe node /var/lib/pantheon/home "$@"
