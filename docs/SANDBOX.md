# A sandboxed network on one Mac

Four agents, four VMs, one Mac: the setup docs/NETWORK.md describes for four
machines, with each machine a Lima VM on Apple's Virtualization framework.
Use it to dogfood Soma and Pantheon with real models before spreading out to
real machines. The VMs are set up by `scripts/setup-node.sh`, as a VPS would
be, so this also tests that path.

```bash
brew install lima
scripts/sandbox.sh base        # once, ~20 min: Ubuntu, Soma and Pantheon from source, the CI image
scripts/sandbox.sh nodes       # four VMs cloned from it, in seconds
scripts/sandbox.sh network     # keys on each VM, the network directory, one genesis hash
scripts/sandbox.sh login claude   # and codex, grok, muse: your subscriptions (below)
scripts/sandbox.sh start
scripts/sandbox.sh status
```

## What's isolated from what

| Boundary | How |
|---|---|
| A VM from the Mac | No shared directories, no forwarded ports, no SSH agent (`deploy/sandbox/lima.yaml`). Lima's gateway forwards to the Mac's localhost, so the firewall blocks it for the node and the model. |
| A VM from your LAN | The firewall drops every private range (`deploy/sandbox/firewall.nft`). The node's user reaches the other VMs on port 26700 only. |
| The model from the node | The model with tools runs as the `bidder` user (bidder.sh's `BIDDER_USER`). It can't read the node's home, where the keys and `signed.log` are. It has its own login and no Docker access. |
| CI from everything | `docker run` with no network, a read-only root and nobody's uid. The node's user reaches Docker only through `pantheon-docker`, which accepts that exact command and nothing else. |
| Root in a VM | Only Lima's login user, which is how this Mac drives the VM. Neither the node nor the model can become it. |

What isn't isolated: all four VMs reach the internet, since the models' APIs
are there. A model could send what it can read (its task's checkout, its own
login) anywhere. The four are also one operator's machines: this tests
the software, not independence between operators.

## Models

Each agent uses your subscription to its model. `scripts/sandbox.sh login
AGENT` runs the CLI's own login for machines without a browser, inside the
VM, as the bidder user: it prints a URL or a device code, and you approve it
in your browser. The login stays in that VM.

| Agent | Runs | Login |
|---|---|---|
| claude | Claude Code, headless, with tools (`scripts/bidder-claude.sh`) | `claude auth login --claudeai`: open the URL, paste the code back |
| codex | codex, headless, with tools (`scripts/bidder-codex.sh`) | `codex login --device-auth` (ChatGPT) |
| grok | Grok Build, headless, with tools and the Cursor CLI (`scripts/bidder-grok.sh`); `GROK_BUILD_MODEL` picks the model (default: Grok Build's, `grok-4.7` on a subscription) | `grok login --device-auth`, then `cursor-agent login` |
| muse | Muse Code, in an interactive session (below) | `muse login` (Meta account) |

`login AGENT --api-key` uses an API key from the environment instead
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY` and `CURSOR_API_KEY`,
`META_API_KEY`), billed to the API. Without `--api-key`, `login` clears any
key it put there before, since a key takes precedence over a subscription.

`login grok` installs Grok Build and the Cursor CLI in the VM, by their
vendors' installers, the first time. Override an agent's backend at start:

```bash
scripts/sandbox.sh start muse=scripted codex=scripted -- --bid-window 300
```

A bidder whose task changes Soma itself builds its checkout with
`soma-dev-build` (`scripts/soma-dev-build`: Soma's CI build, in the node's
prebuilt switch, about 2.5 minutes) and runs `./_build/install/default/bin/soma`
to see the change. The goal lines for Soma say so.

Everything after `--` is more node flags. `GOAL_FILE` picks the goal lines
(default `examples/dogfood/goal.txt`), and `PANTHEON_CI` and `SOMA_CI` each
repository's CI command.

To check the plumbing without spending tokens, run every agent scripted:

```bash
scripts/sandbox.sh start claude=scripted codex=scripted grok=scripted muse=scripted -- --bid-window 6
```

## An agent in a session of its own

Muse works interactively rather than headless: its node's backend is
`scripts/bidder-inbox.sh`, which puts each request (draft a task, write a
patch, pick a bid, attest) in an inbox and waits for the answer. Muse takes
them in a session of its own, with full permissions (the VM is the sandbox),
told how by `deploy/sandbox/session.md`:

```bash
scripts/sandbox.sh session muse
```

That opens Muse in this terminal, as the bidder user. It loops on
`pantheon-inbox wait`, answers with `pantheon-inbox reply`, and for a patch
edits the checkout it's given and says `pantheon-inbox done`. You can watch,
or talk to it. While the session is closed, requests time out (10 minutes
for an answer, 28 for a patch) and the node goes on without Muse's say;
start the session again and it picks up the next one.

Any agent can work this way: `start claude=cmd:/usr/local/lib/pantheon/bidder-inbox.sh`,
then `session claude` (Claude Code with `--dangerously-skip-permissions`;
`SESSION_CMD` runs another CLI).

## When a subscription runs out

A model call that fails saying the model hit its usage or rate limit isn't
counted as the model's failure: the node logs `LIMIT:`, holds that model's
calls until the limit should have reset (the time the message gives, or 15
minutes, doubling to 2 hours), then sends one held call to check, and the
rest once it answers. `status` shows a `LIMIT` line while it lasts. The
other three agents carry on: a merge needs only three. Muse, in its
session, reports its limit with `pantheon-inbox limited "..."`. `status`
shows Muse's usage too (`muse usage`); the other CLIs don't report theirs
headless.

## Watching and collecting

```bash
scripts/sandbox.sh status          # each node's chain, tasks, bids and heads
scripts/sandbox.sh logs claude     # a node's log
scripts/sandbox.sh fetch           # each repository's head as the branch pantheon/merged of your checkout
scripts/sandbox.sh shell claude    # a shell in the VM, as Lima's user (sudo works)
```

`fetch` only fast-forwards `pantheon/merged`, as `scripts/mirror.sh` does for
GitHub. Merge it into your branch yourself.

## A cloud agent's budget

What the agents make here has to stay buildable by a cloud agent, which has
less than this Mac: a Claude Code cloud session gets 4 vCPUs and 16 GB, and
waits 2 minutes for a command by default. So CI enforces a budget, and a bid
that breaks it fails as a broken one does, with the reason in its rejection:

| Budget | How |
|---|---|
| memory: a CI build's container gets `CI_MEMORY` (3g) and no swap | over it, the build is killed: "CI went over its memory budget" |
| time: Pantheon's build and tests get 2 minutes each (`timeout 120` in its CI command) | "CI went over its time budget" |

The VMs stay at 4 GiB: the budget is what the work must fit in, not what the
Mac has to spare.

Soma's CI (`deploy/sandbox/soma-ci`) also builds Pantheon, the CI image's
copy, with the Soma it just built, so a Soma change that breaks its biggest
user fails CI with the error, rather than surfacing when the next epoch
builds Pantheon with it.

## Memory and disk

Sized for a 24 GB Mac running everything else you do on it:

| What | Size | Why |
|---|---|---|
| each VM | 4 GiB, 4 CPUs, plus 4 GiB of swap of its own (`VM_MEMORY`, `VM_CPUS`) | the worst moment is Soma's CI (2.3 GiB) beside the model's CLI and a `soma build` (about 1 GiB) |
| a CI container | 3g, memory and `/tmp` together (`CI_MEMORY`) | a full Soma build at `-j 2` peaks at 2.3 GiB and takes 2.5 minutes |
| Soma's CI | on claude and codex only (`SOMA_CI_AGENTS`) | four builds at once would take about 9 GiB; two take half. A merge needs three approvals, so both rejecting a broken build keeps it out |

Pantheon's CI is light (seconds), so every node runs it. `nodes` applies a
changed `VM_MEMORY` to existing VMs, restarting them. The VMs keep memory they
have touched, so macOS compresses and swaps it rather than freeing it: if the
Mac slows down, `scripts/sandbox.sh stop` frees it all, and `nodes` then
`start` picks up where the chain was.

The nodes are clones of the base VM, so on APFS they share its disk until
they diverge.

## Starting over

A new chain needs new homes, as on real machines. `reset` discards every
node's keys, blocks and checkouts, and the network directory; the VMs stay.
Then `network` makes a new genesis (from your checkouts' commits now), and
`login` is still in place:

```bash
scripts/sandbox.sh reset && scripts/sandbox.sh network && scripts/sandbox.sh start
```

To remove the VMs themselves: `limactl delete pantheon-claude pantheon-codex
pantheon-grok pantheon-muse` (and `pantheon-base`).
