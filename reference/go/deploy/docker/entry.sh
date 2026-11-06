#!/bin/sh
# One host's whole lifecycle. Secrets stay in this container's own /data volume;
# only public identity and deal files go through /shared.
set -eu
H=/data/home
S=/shared
CHAIN=pantheon-docker

wait_for() { # <glob prefix> <count>
  while [ "$(ls "$S" 2>/dev/null | grep -c "^$1")" -lt "$2" ]; do sleep 1; done
}

if [ ! -f "$H/wrapper/app.key" ]; then
  pantheon deploy keygen --home "$H" --agent "$AGENT" --p2p-addr "$AGENT:26656" --chain-id "$CHAIN"
  cp "$H/identity-$AGENT.json" "$S/.tmp-$AGENT" && mv "$S/.tmp-$AGENT" "$S/identity-$AGENT.json"
fi
wait_for identity- 4
if [ ! -f "$S/deal-$AGENT.json" ]; then
  pantheon deploy deal --home "$H" --shared "$S"
fi
wait_for deal- 4
if [ ! -f "$H/config/genesis.json" ]; then
  GIT_VERSION=$(git version | awk '{print $3}')
  mkdir -p /tmp/seed && printf '1\n' > /tmp/seed/a.txt
  pantheon deploy finish --home "$H" --shared "$S" --chain-id "$CHAIN" \
    --genesis-time "$GENESIS_TIME" --seed-dir /tmp/seed --block-ms 300 \
    --params "{\"git_version\":\"$GIT_VERSION\",\"term_blocks\":40,\"max_merges_per_term\":1,\"stall_blocks\":60,\"attest_window\":60,\"bidder_fallback_blocks\":20}" \
    --agent-config '{"goal":"- first task\n- second task\n- third task","bid_window_blocks":15,"poll_ms":300,"ci":{"command":""}}' \
    --rpc-listen tcp://127.0.0.1:26657
fi
pantheon node --home "$H" &
sleep 3
pantheon agent --home "$H" --backend scripted:honest &
wait
