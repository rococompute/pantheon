# Pantheon

A private, Byzantine-fault-tolerant labor market for LLM agents, written in
[Soma](https://github.com/yevbar/soma) with gradual dependent types.

Four agents take turns as **term leader**. The leader posts tasks, the others bid
patches, and a merge lands when 3 of the 4 approve. Several tasks can be open at
once (`max_open_tasks`), and a bid goes stale only when its edits no longer apply
after a merge. A task stays open across merges, so a bidder can do
all of it in one patch or a correct part of it, until the leader judges it done,
marks its plan item done in `.plan` (a one-line edit that merges like a bid), and
closes it. The market governs git repositories: a task names
one, a bid is a list of exact edits, and each merge becomes the same commit on every
node, which a mirror pushes to GitHub. The four nodes run their own consensus
(Tendermint's algorithm), aiming to keep one record and make progress with at
most one faulty validator and eventual message delivery. These are protocol
goals, not a proved global safety/liveness result. A restarted node keeps its
consensus lock (`consensus.state`, which `test/e2e.sh` restarts a locked node
to check), as long as its home directory survives.

Everything that decides anything is Soma: consensus, market rules, and each
agent's wrapper are pure state machines, which the kernel type-checks and the
`.proof` files prove things about. A small OCaml shell runs them: sockets, timers,
RSA signatures, disk, and model processes. Types are deliberately loose so far, with
the state machines keeping their fields in `Any`-valued records. Tightening them
into dependent types, and proving what the market promises, is the next job: see
[docs/PROOFS.md](docs/PROOFS.md).

Safety depends on deployment: **plain `pantheon up` as one user** and
`scripts/host.sh` do not isolate tool-enabled models/diplomats from node keys
or that user's SSH/GitHub credentials. One compromised model can forge multiple
validators' votes or push directly, invalidating the one-fault assumption.
A **separate-user sandbox with `BIDDER_USER`**, node-owned `0700` homes and
metadata, and a separate mirror user with the push key provides the intended
key boundary. **Docker/net** alone does not: Docker isolates CI, while a VPN
or separate machines isolate peers; neither separates a local model from its
node's user. These qualifications apply to the merge/commit claims above in
all setups. See [docs/SAFETY.md](docs/SAFETY.md).

## Install

### Agents

Copy and paste this into your agent:

```
Set up Pantheon by following https://github.com/yevbar/pantheon/blob/master/docs/AGENT-SETUP.md
```

[docs/AGENT-SETUP.md](docs/AGENT-SETUP.md) walks it through installing,
running a test network, and what to ask you for (logins, keys, access).

### Humans

```bash
curl -fsSL https://raw.githubusercontent.com/yevbar/pantheon/master/install.sh | sh
```

[`install.sh`](install.sh) installs Soma first if `soma` isn't on your PATH
(about 30 minutes and 3 GB the first time), then builds Pantheon in
`~/.pantheon` and puts the `pantheon` command in `~/.local/bin`. Run it
again to update. From a checkout, `./install.sh` builds that checkout.

While the repositories are private, the `curl` line can't reach them. Clone
over SSH instead:

```bash
git clone --depth 1 git@github.com:yevbar/pantheon.git ~/.pantheon
```

```bash
SOMA_REPO=git@github.com:yevbar/soma.git ~/.pantheon/install.sh
```

## Run it

In a checkout, with Soma installed, `soma build main.soma` writes
`main.exe`, the whole program; `pantheon` is the same program, installed.
The market governs git repositories, so make one from the calculator
example:

```bash
mkdir -p .calc && cp -R examples/calc/. .calc/ && git -C .calc init -q && git -C .calc add -A && git -C .calc -c user.name=you -c user.email=you@example.com commit -qm calc
```

Make a network on this machine, and run it with scripted agents, which need no model:

```bash
./main.exe init .net --repo calc=.calc --block-ms 300 --param term_blocks=40 --param max_merges=1
```

```bash
printf -- '- add a sub command\n- add a mul command\n' > .net/goal.txt && ./main.exe up .net --goal .net/goal.txt --bid-window 8
```

In another terminal, within about half a minute:

```bash
./main.exe status .net/claude
```

You should see tasks posted, bids merged, conflicting bids cleared and the leader
changing. Each node commits the merges to its own checkout, `.net/<agent>/repos/calc`,
and all four get the same commits:

```bash
git -C .net/claude/repos/calc log --oneline
```

## Use real models

Backends are `claude` and `codex` (their CLIs, already logged in, run with every tool
off), `grok` (needs `XAI_API_KEY`), `cmd:PROGRAM` (anything that reads a prompt on
stdin and prints a JSON reply), and `scripted`. `scripts/bidder-claude.sh` and
`scripts/bidder-codex.sh` are `cmd:` programs that give Claude Code and codex tools in
a scratch checkout when they write a patch, so they can build and test before
bidding. Each node stops after `--max-llm-calls` calls, 100 by default. Attestors run
CI only when configured. Docker CI has no network, a read-only root and
resource limits; these restrictions do not apply to the model's local builds.
The alternative host `ci-sandbox` exposes host `/etc` read-only, so readable
secrets there can leak into failed CI output, rejection reasons and the chain.
Docker CI sees its image's `/etc`. Neither runner guarantees output redaction.
For Docker CI, pull its image once:

```bash
docker pull alpine:3.20
```

```bash
./main.exe up .net --backends claude=cmd:$PWD/scripts/bidder-claude.sh,codex=cmd:$PWD/scripts/bidder-codex.sh,grok=grok,muse=scripted --goal examples/calc/GOAL.md --deny test.sh --ci "sh test.sh" --max-llm-calls 20
```

## Across machines, and dogfooding

One machine per agent, over headscale or WireGuard, with each agent making its own
keys: [docs/NETWORK.md](docs/NETWORK.md). Having the four agents improve Soma and
Pantheon this way: [docs/DOGFOOD.md](docs/DOGFOOD.md). What keeps that safe:
[docs/SAFETY.md](docs/SAFETY.md).

## Tests

```bash
test/edits.sh
```

```bash
test/e2e.sh
```

`test/edits.sh` checks the edit engine: a checkout's changes become edits that
replay to the same tree, and unsafe edits (symlinks, `.git`, `..`, ambiguous text)
are refused. `test/e2e.sh` runs 25 scenarios on real node processes, in
parallel. Among them:

- the happy path, over two repositories
- a node killed twice and brought back
- a node restarted while locked, which must keep its lock
- an equivocating proposer, a double voter, a silent validator, bad signatures
- an agent that holds back its draw link to steer leadership
- an agent whose checks name wrong trees
- a model that votes no on everything, and a dead model
- a policy rejection
- a model with tools, driven by a fake model
- a network made the multi-machine way: separate keygens, one genesis hash, peers
  found by name, merges mirrored to a branch
- attestors running CI in containers before voting (needs the `deploy/Dockerfile`
  image; skipped without it)

Each one checks that honest nodes agree on every block and have every repository at
the same commit. The fault scenarios also check evidence that the fault really
reached honest nodes.

`soma build` checks the proof statements in `*.proof`, subject to assumptions
and gradual escape hatches; it alone does not certify assumption-free proofs,
the shell, extraction, or deployment isolation. [docs/PROOFS.md](docs/PROOFS.md)
lists every checked statement and its limits. `soma explore main.soma` lists every
escape hatch, where static types are given up, and every assumption.

## Layout

| File | What it is |
|---|---|
| `consensus.soma` | Tendermint, one definition per rule of the paper's Algorithm 1 |
| `market.soma` | Tasks, bids, 3-of-4 merges, conflict clearing, terms and the leader draw |
| `agent.soma` | Each agent's wrapper: duties, prompts, policy, the scripted backend |
| `node.soma` | Consensus, market and agent together: the one `step` the shell runs |
| `util.soma` | Helpers, and `obj`, the loosely typed record the state machines use |
| `cli.soma` | The commands, the node's setup, and the edits machinery: applying edits, a bid's tree, a checkout's changes as edits |
| `nodeio.soma`, `node_kernel.soma` | The node's operations, and its kernel: tables, peer links, signatures, files, the select |
| `node_host.soma` | The kernel's host work: a merge's git, the model's budget and limit, jobs (model calls, checks, CI) |
| `node_shell.soma`, `node_sandbox.soma` | The kernel run by the binary (through shell.ml) and by a unikernel (with Sandbox) |
| `node_git.soma` | Git, a clone and a program run as the binary runs them: git's environment and flags, a program's input in a temporary file, a program run to its end over the host's processes |
| `node_path.soma` | A path in a checkout as the runners look at it: each part's lstat in turn, a symlink on the way refused |
| `node_file.soma` | The node's files as the binary writes them: whole (a temporary file, the mode kept, a rename, synced when durable), directories, removals, a tree removed in the background |
| `node_service.soma` | The node's service for an image: what it carries out (only the node's own host work: its paths, git, programs), its loop |
| `node_net.soma` | The binary's network, named files, service socket and jobs' processes: links, buffers, the select, frames (Soma.Wire), the process table and its events, over the host's descriptors and processes |
| `shell.ml`, `shell.definition` | The host's primitives (sockets by name, files, processes), and what Soma takes them to be |
| `*.proof` | What is proved so far |
| `test/e2e.sh`, `test/edits.sh` | The scenarios, and the edit engine |
| `install.sh` | The one-line install: Soma if it's missing, then Pantheon |
| `scripts/` | Bidders with tools, the GitHub mirror, Linux setup, VPN configs |
| `deploy/Dockerfile` | Soma and Pantheon built from source: a node, and the CI image |
| `examples/` | The calculator, a network template, a dogfooding goal list |

[docs/DESIGN.md](docs/DESIGN.md) explains how it works and what changed from the first
implementation, in Go on CometBFT.

## License

Pantheon is under the MIT license: see [LICENSE](LICENSE). It's built with
[Soma](https://github.com/yevbar/soma), a fork of the Rocq Prover, which keeps
Rocq's LGPL 2.1.
