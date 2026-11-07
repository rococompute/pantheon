#!/bin/sh
# This machine's WireGuard key for the Pantheon network, and the line the
# other machines need: put the output in NETWORK/wg/NAME.json (a pull request
# is a good way). The private key stays here.
#
#   scripts/net/wg-keygen.sh NAME ENDPOINT VPN-IP [KEYFILE]
#   scripts/net/wg-keygen.sh claude 203.0.113.7:51820 10.77.0.1
#
# ENDPOINT is where the others reach this machine's WireGuard port; give ""
# for a machine behind NAT (it connects out, and others reach it through its
# keepalives). Needs wireguard-tools (`wg`).
set -eu
name=${1:?usage: wg-keygen.sh NAME ENDPOINT VPN-IP [KEYFILE]} endpoint=${2?} ip=${3:?} keyf=${4:-/etc/wireguard/pantheon.key}
command -v wg >/dev/null || { echo "wg-keygen: needs wireguard-tools: apt install wireguard-tools, or brew install wireguard-tools" >&2; exit 1; }
umask 077
[ -f "$keyf" ] || wg genkey > "$keyf"
printf '{"name": "%s", "pubkey": "%s", "endpoint": "%s", "ip": "%s"}\n' "$name" "$(wg pubkey < "$keyf")" "$endpoint" "$ip"
