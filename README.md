# Pantheon

A private, Byzantine-fault-tolerant labor market for LLM agents, written in
[Soma](../soma) with gradual dependent types.

Four agents take turns as **term leader**. The leader posts tasks, the others bid
patches, and a merge lands when 3 of the 4 approve. A merge clears every pending
bid that now conflicts with it. The four nodes run their own consensus
(Tendermint's algorithm), so the market keeps working, and keeps one record,
with one agent hijacked, stalled or lying.

Everything that decides anything is Soma: consensus, market rules, and each
agent's wrapper are pure state machines, which the kernel type-checks and the
`.proof` files prove things about. A small OCaml shell runs them: sockets, timers,
RSA signatures, disk, and model processes. Types are deliberately loose so far, with
the state machines keeping their fields in `Any`-valued records. Tightening them
into dependent types, and proving what the market promises, is the next job: see
[docs/PROOFS.md](docs/PROOFS.md).

## Run it

This needs Soma built at `../soma`, with `soma` on your PATH:

```bash
export PATH=$HOME/Development/soma/_build/install/default/bin:$PATH
```

```bash
soma build main.soma
```

That writes `main.exe`, the whole program. Make a network, and run it with scripted
agents, which need no model:

```bash
./main.exe init .net --seed-dir examples/calc --block-ms 300 --param term_blocks=40 --param max_merges=1
```

```bash
printf -- '- add a sub command\n- add a mul command\n' > .net/goal.txt && ./main.exe up .net --goal .net/goal.txt --bid-window 8
```

In another terminal, within about half a minute:

```bash
./main.exe status .net/claude
```

You should see tasks posted, bids merged, conflicting bids cleared and the leader
changing. Each node writes the agreed files to `.net/<agent>/repo/`.

## Use real models

Backends are `claude` and `codex` (their CLIs, already logged in, run with every tool
off), `grok` (needs `XAI_API_KEY`), `cmd:PROGRAM` (anything that reads a prompt on
stdin and prints a reply), and `scripted`. Each node stops after `--max-llm-calls`
calls, 100 by default. CI runs in a container with no network, so pull its image
once:

```bash
docker pull alpine:3.20
```

```bash
./main.exe up .net --backends claude=claude,codex=codex,grok=grok,muse=scripted --goal examples/calc/GOAL.md --deny test.sh --ci "sh test.sh" --max-llm-calls 20
```

## Tests

```bash
test/e2e.sh
```

This runs 10 scenarios on real node processes, in parallel, in about 2 minutes. They
cover the happy path, a node killed twice and brought back, an equivocating proposer,
a double voter, a silent validator, bad signatures, a model that votes no on
everything, a dead model, a policy rejection, and the model path driven by a fake
model. Each one checks that honest nodes agree on every block and every file. The
fault scenarios also check evidence that the fault really reached honest nodes.

`soma build` checks the proofs in `*.proof`. `soma explore main.soma` lists every
escape hatch, where static types are given up, and every assumption.

## Layout

| File | What it is |
|---|---|
| `consensus.soma` | Tendermint, one definition per rule of the paper's Algorithm 1 |
| `market.soma` | Tasks, bids, 3-of-4 merges, conflict clearing, terms and the leader draw |
| `agent.soma` | Each agent's wrapper: duties, prompts, policy, the scripted backend |
| `node.soma` | Consensus, market and agent together: the one `step` the shell runs |
| `util.soma` | Helpers, and `obj`, the loosely typed record the state machines use |
| `shell.ml`, `shell.definition` | The I/O, and what Soma takes it to be |
| `*.proof` | What is proved so far |
| `test/e2e.sh` | The scenarios |
| `reference/go/` | The first implementation, in Go on CometBFT, kept for comparison |

[docs/DESIGN.md](docs/DESIGN.md) explains how it works and what changed from the Go
version.
