#!/bin/sh
# A whole Pantheon network on one Linux host, for agents that work from
# elsewhere: four nodes as systemd user services, CI in a sandbox
# (deploy/host/ci-sandbox), each agent's inbox served over HTTP
# (scripts/inbox-http.py) on localhost, behind something that gives it a
# public HTTPS name: Tailscale Funnel (tailscale funnel --bg 8787, then
# `url`) or a Cloudflare tunnel (`tunnel`). No VMs and no Docker: it fits a
# small machine.
#
#   scripts/host.sh network            keys, the network and its genesis (once), for Pantheon at HEAD
#   scripts/host.sh token AGENT        a new inbox token for AGENT, printed once
#   scripts/host.sh url URL            the inbox's public URL, as agents reach it (https://zucc.example.ts.net)
#   scripts/host.sh tunnel HOSTNAME    or a Cloudflare tunnel to HOSTNAME (after: cloudflared tunnel login)
#   scripts/host.sh start              write the services and (re)start them all
#   scripts/host.sh stop               stop the nodes, the inbox server and the tunnel
#   scripts/host.sh status             each node's chain, limits, inbox, and the services
#   scripts/host.sh logs [AGENT]       follow a node's log (or the inbox server's)
#
# Everything lives in PANTHEON_HOST (default ~/pantheon): soma/ and pantheon/
# (built by scripts/setup-node.sh), net/ (the nodes' homes), inbox/ (one per
# agent), inbox.json (the server's tokens, as hashes), goal.txt.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
P=${PANTHEON_HOST:-$HOME/pantheon}
NET=$P/net AGENTS="claude codex grok muse"
BIN=$here/main.exe SOMA=${SOMA_DIR:-$P/soma}
CI_MEMORY=${CI_MEMORY:-1536m}
CI_CMD=${PANTHEON_CI:-timeout 120 soma build main.soma && timeout 120 test/edits.sh}
PORT=${INBOX_PORT:-8787}
UNITS=$HOME/.config/systemd/user
say() { printf 'host: %s\n' "$*"; }
die() { printf 'host: %s\n' "$*" >&2; exit 1; }
need_bin() { [ -x "$BIN" ] || die "no $BIN: build Pantheon first (SOMA_DIR=$SOMA scripts/setup-node.sh)"; }
url() { python3 -c "import json; print(json.load(open('$P/inbox.json')).get('url', ''))" 2>/dev/null || true; }

cmd_network() {
  need_bin
  [ ! -d "$NET" ] || die "$NET already holds a network. A new chain is a new network: stop it, move $NET away, and run this again"
  commit=$(git -C "$here" rev-parse HEAD)
  # the cloud run's parameters (examples/network/network.json): an hour's
  # term, attest window and stuck-task limit; fallback after 15 minutes
  "$BIN" init "$NET" --repo "pantheon=$here" --base-port 26701 --block-ms 1000 \
    --param term_blocks=3600 --param max_merges=2 --param stall_blocks=1800 --param attest_window=3600 \
    --param fallback_blocks=900 --param reveal_window=30 --param bid_cooldown=5
  [ -f "$P/goal.txt" ] || cp "$here/examples/cloud/goal.txt" "$P/goal.txt"
  mkdir -p "$P/inbox"; for a in $AGENTS; do mkdir -p "$P/inbox/$a"; done
  say "a network for Pantheon at $(git -C "$here" log -1 --format='%h %s' "$commit"); goals in $P/goal.txt"
  say "next: scripts/host.sh token AGENT (each agent), scripts/host.sh tunnel HOSTNAME, scripts/host.sh start"
}

cmd_token() {
  a=${1:-}; case " $AGENTS " in *" $a "*) ;; *) die "usage: scripts/host.sh token AGENT (one of: $AGENTS)" ;; esac
  mkdir -p "$P/inbox/$a"
  t=$(python3 "$here/scripts/inbox-http.py" token "$P/inbox.json" "$a" "$P/inbox/$a")
  python3 - "$P/inbox.json" "127.0.0.1:$PORT" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c['listen'] = sys.argv[2]; json.dump(c, open(sys.argv[1], 'w'), indent=1)
PY
  say "$a's token (shown once; a new one replaces it; restart the inbox server with scripts/host.sh start):"
  printf '%s\n' "$t"
}

cmd_tunnel() {
  h=${1:-}; [ -n "$h" ] || die "usage: scripts/host.sh tunnel HOSTNAME (a name under a domain on your Cloudflare account)"
  command -v cloudflared >/dev/null || die "no cloudflared: install it (pkg.cloudflare.com)"
  [ -f "$HOME/.cloudflared/cert.pem" ] || die "not logged in to Cloudflare: run cloudflared tunnel login, open the URL it prints, and pick the domain"
  cloudflared tunnel list -o json 2>/dev/null | grep -q '"name":"pantheon"' || cloudflared tunnel create pantheon
  id=$(cloudflared tunnel list -o json | python3 -c "import json,sys; print([t['id'] for t in json.load(sys.stdin) if t['name'] == 'pantheon'][0])")
  cloudflared tunnel route dns pantheon "$h" || say "(the DNS route may exist already)"
  cat > "$HOME/.cloudflared/pantheon.yml" <<Y
tunnel: $id
credentials-file: $HOME/.cloudflared/$id.json
ingress:
  - hostname: $h
    service: http://127.0.0.1:$PORT
  - service: http_status:404
Y
  set_url "https://$h"
  say "tunnel pantheon ($id) to https://$h. Next: scripts/host.sh start"
}

set_url() {
  [ -f "$P/inbox.json" ] || printf '{"listen": "127.0.0.1:%s", "url": "", "agents": {}}\n' "$PORT" > "$P/inbox.json"
  python3 - "$P/inbox.json" "$1" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c['url'] = sys.argv[2].rstrip('/'); json.dump(c, open(sys.argv[1], 'w'), indent=1)
PY
}

cmd_url() {
  case ${1:-} in https://*) ;; *) die "usage: scripts/host.sh url https://NAME (where agents reach the inbox)" ;; esac
  set_url "$1"; say "the inbox's public URL is $1. Next: scripts/host.sh start (patch prompts and instructions name it)"
}

cmd_start() {
  need_bin
  [ -d "$NET" ] || die "no network yet: scripts/host.sh network"
  u=$(url); [ -n "$u" ] || say "no public URL yet (scripts/host.sh url URL, or tunnel HOSTNAME): patch prompts will say http://127.0.0.1:$PORT"
  [ -n "$u" ] || u=http://127.0.0.1:$PORT
  q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
  for a in $AGENTS; do
    # the node strips PANTHEON_* from a backend's environment: the backend sets its own
    cat > "$NET/$a/backend.sh" <<B
#!/bin/sh
PANTHEON_INBOX=$P/inbox/$a INBOX_URL=$u exec $here/scripts/bidder-inbox.sh
B
    cat > "$NET/$a/run.sh" <<R
#!/bin/sh
exec $BIN node $NET/$a --backend cmd:$NET/$a/backend.sh --goal $P/goal.txt --listen 127.0.0.1 \\
  --ci-repo pantheon $(q "$CI_CMD") --ci-sandbox $here/deploy/host/ci-sandbox --ci-memory $CI_MEMORY
R
    chmod 755 "$NET/$a/backend.sh" "$NET/$a/run.sh"
  done
  mkdir -p "$UNITS"
  cat > "$UNITS/pantheon-node@.service" <<U
[Unit]
Description=Pantheon node %i
[Service]
Environment=SOMA_DIR=$SOMA
ExecStart=$NET/%i/run.sh
Restart=on-failure
RestartSec=10
[Install]
WantedBy=default.target
U
  cat > "$UNITS/pantheon-inbox.service" <<U
[Unit]
Description=Pantheon inbox over HTTP
[Service]
ExecStart=/usr/bin/python3 $here/scripts/inbox-http.py serve $P/inbox.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
U
  units="pantheon-inbox.service"
  if [ -f "$HOME/.cloudflared/pantheon.yml" ]; then
    cat > "$UNITS/pantheon-tunnel.service" <<U
[Unit]
Description=Cloudflare tunnel for the Pantheon inbox
[Service]
ExecStart=$(command -v cloudflared) --no-autoupdate tunnel --config $HOME/.cloudflared/pantheon.yml run pantheon
Restart=on-failure
RestartSec=10
[Install]
WantedBy=default.target
U
    units="$units pantheon-tunnel.service"
  fi
  [ -f "$P/inbox.json" ] || say "no tokens yet (scripts/host.sh token AGENT): the inbox server answers no one"
  [ -f "$P/inbox.json" ] || printf '{"listen": "127.0.0.1:%s", "url": "", "agents": {}}\n' "$PORT" > "$P/inbox.json"
  for a in $AGENTS; do units="$units pantheon-node@$a.service"; done
  systemctl --user daemon-reload
  # every node at once: restarting them one by one mid-height stalls the chain
  systemctl --user enable -q $units
  systemctl --user restart $units
  say "started: $units"
  say "watch it: scripts/host.sh status"
}

cmd_stop() { systemctl --user stop pantheon-tunnel.service pantheon-inbox.service $(for a in $AGENTS; do printf 'pantheon-node@%s ' "$a"; done) 2>/dev/null; say "stopped"; }

cmd_status() {
  for a in $AGENTS; do
    printf '== %s (%s)\n' "$a" "$(systemctl --user is-active "pantheon-node@$a" 2>/dev/null || true)"
    sed -n '1,3p' "$NET/$a/status.txt" 2>/dev/null | sed 's/^/   /'
    grep -h '^LIMIT' "$NET/$a/status.txt" 2>/dev/null | sed 's/^/   /' || true
    n=$(ls "$P/inbox/$a" 2>/dev/null | grep -c '^[0-9]*-' || true); [ "$n" = 0 ] || printf '   inbox: %s waiting\n' "$n"
  done
  printf '== tasks and bids (claude'"'"'s view)\n'; grep -E '^(task|bid) ' "$NET/claude/status.txt" 2>/dev/null | cut -c1-160 | tail -12 | sed 's/^/   /' || true
  printf '== services: inbox %s, tunnel %s; url %s\n' "$(systemctl --user is-active pantheon-inbox 2>/dev/null || true)" \
    "$(systemctl --user is-active pantheon-tunnel 2>/dev/null || true)" "$(url)"
  printf '== memory: %s\n' "$(free -m | awk '/^Mem/ {print $7 " MB available of " $2}')"
}

cmd_logs() {
  case ${1:-} in
    '') exec journalctl --user -f -u pantheon-inbox -u pantheon-tunnel ;;
    *) exec journalctl --user -f -u "pantheon-node@$1" ;;
  esac
}

c=${1:-}; [ $# -gt 0 ] && shift
case $c in
  network|token|url|tunnel|start|stop|status|logs) "cmd_$c" "$@" ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; [ -z "$c" ] || exit 1 ;;
esac
