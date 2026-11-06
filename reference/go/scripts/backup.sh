#!/bin/sh
# Backs up one node's market data. Usage: backup.sh <home> <dest-dir>
#
# Keys are deliberately left out: back those up separately and offline. So is
# priv_validator_state.json, because restoring an old copy can make a validator
# sign twice at one height, which is the one thing it must never do. Consensus data
# is left out too: a node recovers it from its peers. If this node's data is lost,
# delete data/ apart from priv_validator_state.json, restart, and it replays.
set -eu
home=$1
dest=$2
mkdir -p "$dest"
out="$dest/pantheon-$(basename "$home")-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -czf "$out" -C "$home" config/genesis.json config/config.toml wrapper/agent.json data/market
echo "$out"
