#!/bin/sh
# Makes a fresh Ubuntu 24.04 VM a Pantheon node machine. Runs as root inside
# the VM, from a directory holding this script's siblings plus pantheon.tar
# (Pantheon's source) and soma.tar (Soma's). scripts/sandbox.sh calls it;
# running it again is harmless.
#
# Two users:
#   pantheon  runs the node and owns its identity (/var/lib/pantheon/home).
#             Reaches Docker only through pantheon-docker, for CI.
#   bidder    runs a model with tools (bidder.sh's BIDDER_USER). Holds the
#             model's login, can't read the node's home, can't reach Docker.
# Neither can reach the Mac or the LAN (firewall.nft).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive
say() { printf 'provision: %s\n' "$*"; }

# public resolvers: the VM network's own (192.168.104.2 under vz) has
# answered every AAAA query with SERVFAIL after 2 s, so each lookup took 2-8 s
# and the models' CLIs timed out reaching their providers
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nDomains=~.\n' > /etc/systemd/resolved.conf.d/pantheon-dns.conf
systemctl restart systemd-resolved 2>/dev/null || true

say "system packages"
apt-get update -q >/dev/null
apt-get install -y -q git build-essential opam jq curl m4 pkg-config libgmp-dev rsync ca-certificates \
  docker.io docker-buildx nftables nodejs npm unzip bubblewrap python3 >/dev/null

# Lima's resolver knows .internal peers. Find the networkd unit that owns
# the selected interface instead of assuming eth0 or a netplan filename.
nic=$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<NF; i++) if ($i == "dev") {print $(i+1); exit}}')
[ -n "$nic" ] || { echo "provision: cannot identify the default IPv4 interface" >&2; exit 3; }
network_file=$(LC_ALL=C networkctl status "$nic" --no-pager --no-legend | sed -n 's/.*Network File: //p' | head -1)
[ -n "$network_file" ] && [ -f "$network_file" ] || { echo "provision: no networkd configuration for $nic" >&2; exit 3; }
network_dropin=/etc/systemd/network/$(basename "$network_file").d
mkdir -p "$network_dropin"
printf '[Network]\nDomains=~internal\n' > "$network_dropin/pantheon-dns.conf"
networkctl reload
systemctl restart systemd-resolved

id pantheon >/dev/null 2>&1 || useradd -m -s /bin/bash pantheon
id bidder >/dev/null 2>&1 || useradd -m -s /bin/bash bidder
chmod 755 /home/pantheon; chmod 700 /home/bidder
install -d -o pantheon -g pantheon -m 700 /var/lib/pantheon
install -d -m 755 /etc/pantheon /usr/local/lib/pantheon/bin
install -d -m 755 /var/lib/pantheon-build /usr/local/lib/pantheon/bidder-bin
touch /var/lib/pantheon-build/lock
chmod 644 /var/lib/pantheon-build/lock
install -m 755 "$here/soma-locked" /usr/local/lib/pantheon/bidder-bin/soma
[ -f /etc/pantheon/ci-memory ] || printf '3g\n' > /etc/pantheon/ci-memory

# swap, so four VMs' CI builds at once slow down instead of dying
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
swapon -a 2>/dev/null || true

# The models' own sandboxes (codex's, Muse's) are bubblewrap, which needs
# unprivileged user namespaces; Ubuntu 24.04 restricts them. Inside this VM
# they add a layer on top of the VM and the bidder user.
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' > /etc/sysctl.d/60-pantheon-userns.conf
sysctl -q -p /etc/sysctl.d/60-pantheon-userns.conf || true

say "firewall"
install -m 644 "$here/firewall.nft" /usr/local/lib/pantheon/firewall.nft.in
install -m 644 "$here/render-firewall.py" /usr/local/lib/pantheon/render-firewall.py
install -m 755 "$here/apply-firewall" /usr/local/sbin/pantheon-firewall-apply
# Preserve supported remote Git/native API IO by default. Untrusted-node
# deployments select restricted mode with explicit operator-owned destinations.
[ -f /etc/pantheon/node-egress.json ] || printf '{"mode":"public","allow":[]}\n' > /etc/pantheon/node-egress.json
chown root:root /etc/pantheon/node-egress.json /etc/pantheon/ci-memory
chmod 644 /etc/pantheon/node-egress.json /etc/pantheon/ci-memory
cat > /etc/systemd/system/pantheon-firewall.service <<'U'
[Unit]
Description=Pantheon sandbox firewall
Before=network-pre.target pantheon-node.service
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pantheon-firewall-apply
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload
systemctl enable -q pantheon-firewall
systemctl restart pantheon-firewall

say "docker, for CI only through pantheon-docker"
install -m 755 "$here/pantheon-docker" /usr/local/sbin/pantheon-docker
printf '#!/bin/sh\nexec sudo -n /usr/local/sbin/pantheon-docker "$@"\n' > /usr/local/lib/pantheon/bin/docker
chmod 755 /usr/local/lib/pantheon/bin/docker
[ -f /etc/pantheon/ci-images ] || echo pantheon:dev > /etc/pantheon/ci-images
cat > /etc/sudoers.d/pantheon <<'S'
pantheon ALL=(root) NOPASSWD: /usr/local/sbin/pantheon-docker
pantheon ALL=(bidder) NOPASSWD: ALL
S
chmod 440 /etc/sudoers.d/pantheon
visudo -cq

say "sources"
if [ ! -d /home/pantheon/pantheon ]; then
  install -d -o pantheon -g pantheon /home/pantheon/pantheon
  tar -x -C /home/pantheon/pantheon -f "$here/pantheon.tar"
  chown -R pantheon:pantheon /home/pantheon/pantheon
fi
rm -rf /tmp/soma-src && mkdir /tmp/soma-src && tar -x -C /tmp/soma-src -f "$here/soma.tar" && chown -R pantheon:pantheon /tmp/soma-src

say "Soma and Pantheon, by setup-node.sh (the first time, a while)"
sudo -u pantheon -H sh -c 'cd ~/pantheon && SOMA_REPO=/tmp/soma-src scripts/setup-node.sh' > /var/log/pantheon-setup.log 2>&1 \
  || { tail -30 /var/log/pantheon-setup.log; echo "provision: setup-node.sh failed (log: /var/log/pantheon-setup.log in the VM)" >&2; exit 1; }
tail -1 /var/log/pantheon-setup.log
rm -rf /tmp/soma-src
# The bidder runs soma from the node's build: readable, not writable. opam
# takes its locks and writes its log even to list a switch, so those (and
# only those) are shared, through the group opamshare.
chmod -R a+rX /home/pantheon/soma /home/pantheon/.opam /home/pantheon/.cache /home/pantheon/pantheon
getent group opamshare >/dev/null || groupadd opamshare
usermod -aG opamshare bidder; usermod -aG opamshare pantheon
for d in /home/pantheon/.opam /home/pantheon/.cache/soma/ocaml/_opam; do
  find "$d" -maxdepth 4 \( -name lock -o -name '*.lock' \) -exec chgrp opamshare {} + -exec chmod g+w {} +
done
mkdir -p /home/pantheon/.opam/log && chown pantheon:opamshare /home/pantheon/.opam/log && chmod 2775 /home/pantheon/.opam/log

say "model CLIs"
if [ ! -x /home/bidder/.local/bin/claude ]; then
  sudo -u bidder -H sh -c 'curl -fsSL https://claude.ai/install.sh | bash' >/var/log/pantheon-claude-install.log 2>&1 \
    || { tail -5 /var/log/pantheon-claude-install.log; echo "provision: installing claude failed" >&2; exit 1; }
fi
if [ ! -x /home/bidder/.local/bin/muse ]; then
  sudo -u bidder -H sh -c 'mkdir -p ~/.local/bin && curl -fsSL https://api.meta.ai/muse-launcher.sh -o ~/.local/bin/muse && chmod +x ~/.local/bin/muse' \
    || { echo "provision: installing muse failed" >&2; exit 1; }
fi
[ -x /home/bidder/.grok/bin/grok ] || sudo -u bidder -H sh -c 'curl -fsSL https://x.ai/cli/install.sh | bash' >/dev/null \
  || { echo "provision: installing Grok Build failed" >&2; exit 1; }
[ -x /home/bidder/.local/bin/cursor-agent ] || sudo -u bidder -H sh -c 'curl -fsS https://cursor.com/install | bash' >/dev/null \
  || { echo "provision: installing the Cursor CLI failed" >&2; exit 1; }
codex_js=/usr/local/lib/node_modules/@openai/codex/bin/codex.js
[ -f "$codex_js" ] || npm install -g -s @openai/codex >/dev/null 2>&1 || { echo "provision: installing codex failed" >&2; exit 1; }
# What the bidder runs, through sudo (which resets the environment): its own
# login from ~/.config/pantheon/model.env, and Soma from the node's build,
# with its prebuilt switches, the way CI runs it.
install -m 644 "$here/model-env" /usr/local/lib/pantheon/model-env
rm -f /usr/local/bin/codex
printf '#!/bin/sh\n. /usr/local/lib/pantheon/model-env\nexec /home/bidder/.local/bin/claude "$@"\n' > /usr/local/bin/claude
printf '#!/bin/sh\n. /usr/local/lib/pantheon/model-env\nexec node %s "$@"\n' "$codex_js" > /usr/local/bin/codex
printf '#!/bin/sh\n. /usr/local/lib/pantheon/model-env\nexec /home/bidder/.local/bin/muse "$@"\n' > /usr/local/bin/muse
printf '#!/bin/sh\n. /usr/local/lib/pantheon/model-env\nexec /home/bidder/.grok/bin/grok "$@"\n' > /usr/local/bin/grok
printf '#!/bin/sh\n. /usr/local/lib/pantheon/model-env\nexec /home/bidder/.local/bin/cursor-agent "$@"\n' > /usr/local/bin/cursor-agent
printf '#!/bin/sh\nexec /home/pantheon/soma/_build/install/default/bin/soma "$@"\n' > /usr/local/bin/soma
chmod 755 /usr/local/bin/claude /usr/local/bin/codex /usr/local/bin/muse /usr/local/bin/grok /usr/local/bin/cursor-agent /usr/local/bin/soma
install -d -o bidder -g bidder -m 700 /home/bidder/.config /home/bidder/.config/pantheon

say "node service"
cat > /etc/systemd/system/pantheon-node.service <<'U'
[Unit]
Description=Pantheon node
After=network-online.target docker.service pantheon-firewall.service
Wants=network-online.target
Requires=pantheon-firewall.service
[Service]
User=pantheon
Environment=PATH=/usr/local/lib/pantheon/bin:/home/pantheon/soma/_build/install/default/bin:/usr/local/bin:/usr/bin:/bin
Environment=BIDDER_USER=bidder
EnvironmentFile=-/etc/pantheon/keys.env
ExecStart=/bin/sh /etc/pantheon/node.sh
SyslogIdentifier=pantheon
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload
say "done"
