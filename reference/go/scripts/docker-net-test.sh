#!/bin/sh
# Runs the full market across four Linux containers with separate volumes and IPs:
# dealerless ceremony, consensus, wrappers, one host killed and brought back.
# Needs Docker. Exits 0 only if every check passes.
set -eu
cd "$(dirname "$0")/.."
ARCH=$(docker version --format '{{.Server.Arch}}')
CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" go build -o deploy/docker/pantheon ./cmd/pantheon
export GENESIS_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
export COMPOSE_PROJECT_NAME=pantheon-nettest
DC="docker compose -f deploy/docker/compose.yml"
cleanup() {
  [ "${KEEP:-}" = 1 ] || $DC down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f deploy/docker/pantheon
}
trap cleanup EXIT
$DC down -v --remove-orphans >/dev/null 2>&1 || true
$DC up -d --build --quiet-pull 2>&1 | tail -2

field() { # <service> <json key>: read one field of market state inside a container
  $DC exec -T "$1" pantheon status --json 2>/dev/null | grep -m1 "\"$2\":" | sed 's/.*: *//; s/[",]//g'
}
merged() { $DC exec -T "$1" pantheon status --json 2>/dev/null | grep -c '"status": "merged"' || true; }
wait_until() { # <what> <seconds> <test command...>
  what=$1; limit=$2; shift 2; t=0
  until "$@"; do
    t=$((t + 3)); sleep 3
    if [ "$t" -ge "$limit" ]; then
      echo "FAIL: timed out waiting for $what"
      $DC logs --tail 30 2>&1 | tail -60
      exit 1
    fi
  done
  echo "ok: $what (${t}s)"
}
term_at_least() { v=$(field claude term); [ -n "$v" ] && [ "$v" -ge "$1" ]; }
merged_at_least() { v=$(merged "$1"); [ -n "$v" ] && [ "$v" -ge "$2" ]; }

wait_until "chain started and a leader was drawn" 120 term_at_least 1
wait_until "first bid merged through wrappers" 180 merged_at_least claude 1

echo "killing host grok"
$DC kill grok >/dev/null
before=$(field claude height)
chain_advanced() { v=$(field claude height); [ "$v" -gt "$((before + 10))" ]; }
wait_until "3 of 4 hosts keep making blocks" 120 chain_advanced

echo "restarting host grok"
$DC up -d grok >/dev/null 2>&1
caught_up() { a=$(field grok height); b=$(field claude height); [ -n "$a" ] && [ "$a" -ge "$((b - 3))" ]; }
wait_until "grok caught up" 180 caught_up

wait_until "second bid merged" 240 merged_at_least claude 2

# Every host must report the same head at the same height, checked via a block all have.
same_head() {
  h=$(field claude repo_head)
  for s in codex grok muse; do [ "$(field "$s" repo_head)" = "$h" ] || return 1; done
}
wait_until "all four hosts agree on repo_head" 60 same_head
h=$(field claude repo_head)
for s in claude codex grok muse; do
  got=$($DC exec -T "$s" git -C /data/home/data/market/repo.git rev-parse refs/heads/main)
  [ "$got" = "$h" ] || { echo "FAIL: $s repo at $got, chain says $h"; exit 1; }
  # A host's secrets must not be visible to any other host.
  if $DC exec -T "$s" sh -c 'ls /shared | grep -Ev "^(identity|deal)-"'; then
    echo "FAIL: something other than public files reached /shared"; exit 1
  fi
done
echo "ok: all repos match at $h"
$DC exec -T claude pantheon status | tail -8
echo "PASS"
