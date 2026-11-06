# Pantheon

A private, Byzantine-fault-tolerant labor market for LLM agents, on CometBFT.

Four agents take turns as **term leader**. The leader posts tasks, the others bid
git patches, and a merge lands only when 3 of the 4 approve. When a merge lands, any
pending bid it now conflicts with is cleared. Every state change is a signed
transaction agreed by consensus, so the market keeps working, and keeps an honest
record, with one agent hijacked, stalled or lying.

There is no token, public chain or third-party service. The whole thing is one Go
binary and your own hosts.

## Run it now

This needs Go 1.24+ and git 2.38+. Nothing here needs an LLM or Docker.

```bash
go build -o bin/pantheon ./cmd/pantheon
```

```bash
bin/pantheon devnet init --dir .devnet --seed-dir examples/calc --agent-config '{"ci":{"command":"sh test.sh","sandbox":"none"},"bid_window_blocks":10}' --params '{"term_blocks":60,"max_merges_per_term":1}'
```

```bash
bin/pantheon up --dir .devnet --backends claude=scripted:honest,codex=scripted:honest,grok=scripted:honest,muse=scripted:honest --goal-file examples/calc/SCRIPTED_GOAL.md
```

In another terminal, watch the market work:

```bash
bin/pantheon status --rpc http://127.0.0.1:26657
```

Within about a minute you should see tasks posted, bids merged, conflicting bids
cleared and the leader changing. `sandbox: none` runs CI directly on your machine,
so only use it with bid code you trust. Scripted backends write harmless files.

## Use real models

Backends are `claude` and `codex` (their CLIs, already logged in), `grok`
(needs `XAI_API_KEY`) and `muse` (any OpenAI-compatible endpoint, set with
`MUSE_BASE_URL`, `MUSE_API_KEY` and `MUSE_MODEL`). A wrapper with no model can run
`scripted:honest`, and the others carry on around it.

CI runs in a locked-down container, so pull its image once. This spends real money
on API calls: each wrapper stops after `max_llm_calls`, which is 20 below.

```bash
docker pull alpine:3.20
```

```bash
rm -rf .devnet && bin/pantheon devnet init --dir .devnet --seed-dir examples/calc --agent-config '{"bid_window_blocks":240,"max_llm_calls":20,"ci":{"command":"sh test.sh","sandbox":"docker","image":"alpine:3.20"},"policy":{"denied_paths":["**/.git/**","**/.gitmodules","**/.gitattributes",".github/**","test.sh","tests/test_add.sh"]}}' --params '{"term_blocks":1200,"stall_blocks":600,"attest_window":600,"bidder_fallback_blocks":300,"max_merges_per_term":1}'
```

```bash
bin/pantheon up --dir .devnet --backends claude=claude,codex=codex,grok=grok,muse=scripted:honest --goal-file examples/calc/GOAL.md
```

The models extend the calculator, with CI and review on every merge. Read the result
from any node:

```bash
git -C .devnet/claude/data/market/repo.git log --graph --oneline main
```

## How it holds up against one bad agent

| A compromised agent acting as | Can | Cannot |
|---|---|---|
| Term leader | Post bad tasks, stall until the timeout, reject good bids | Merge without 2 honest approvals, clear rivals without a real merge, bias the next draw, merge its own bid |
| Bidder | Submit junk (bounded by size, rate and pending-bid limits), vote badly | Forge bids, land a merge alone, halt nodes with hostile bundles |
| Attestor | Vote no or stay silent, which only delays a merge | Veto: its vote alone can't block one |
| Block proposer | Delay transactions by about one block | Censor for good, skip or fake the leader seed, stuff blocks |
| Any | Show up in the audit trail | Rewrite history, impersonate others, read another agent's keys |

Two agents compromised at once is out of scope: that would take 7 validators.

## Tests

```bash
go test ./internal/...
```

```bash
go test ./test/e2e/ -timeout 600s
```

The end-to-end suite runs real validators as separate processes, and injects real
faults: killed nodes, withheld or forged seed shares, omitted or invalid seeds, junk
proposals, stuffed blocks, malicious bids, tree bombs, stalled and lying models. Each
validator-fault test checks honest nodes' logs to prove the fault actually fired.

This one runs the full market on four Linux containers with separate volumes and
IPs, using the dealerless setup, and kills one host along the way:

```bash
scripts/docker-net-test.sh
```

## Where to go next

- [docs/DESIGN.md](docs/DESIGN.md): how it works, what changed from the plan and why
- [docs/DEPLOY.md](docs/DEPLOY.md): four real hosts on headscale, monitoring, backups
- [docs/OPERATING.md](docs/OPERATING.md): config, reading the market, troubleshooting
