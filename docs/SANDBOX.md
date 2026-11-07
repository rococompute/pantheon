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
scripts/sandbox.sh login grok  # each model's key (below)
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

`scripts/sandbox.sh login AGENT` puts a model's key where it's used. It
reads it from the environment:

| Agent | Key | Where it goes |
|---|---|---|
| claude | `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token` on this Mac) or `ANTHROPIC_API_KEY` | the bidder user's `~/.config/pantheon/model.env` |
| codex | `OPENAI_API_KEY`, or with none, a device login (`codex login --device-auth`) | the bidder user's codex login |
| grok | `XAI_API_KEY` (and `GROK_MODEL`) | `/etc/pantheon/keys.env`, for the node: grok is a built-in backend with no tools |
| muse | none yet: it runs `scripted` | |

`start` picks each agent's backend: claude and codex run with tools through
`scripts/bidder-claude.sh` and `scripts/bidder-codex.sh`, grok uses the
built-in backend, and anything else is `scripted`. Override per agent:

```bash
scripts/sandbox.sh start muse=cmd:/path/in/the/vm codex=scripted -- --bid-window 300
```

Everything after `--` is more node flags. `GOAL_FILE` picks the goal lines
(default `examples/dogfood/goal.txt`), and `PANTHEON_CI` and `SOMA_CI` each
repository's CI command.

To check the plumbing without spending tokens, run every agent scripted:

```bash
scripts/sandbox.sh start claude=scripted codex=scripted grok=scripted muse=scripted -- --bid-window 6
```

## Watching and collecting

```bash
scripts/sandbox.sh status          # each node's chain, tasks, bids and heads
scripts/sandbox.sh logs claude     # a node's log
scripts/sandbox.sh fetch           # each repository's head as the branch pantheon/merged of your checkout
scripts/sandbox.sh shell claude    # a shell in the VM, as Lima's user (sudo works)
```

`fetch` only fast-forwards `pantheon/merged`, as `scripts/mirror.sh` does for
GitHub. Merge it into your branch yourself.

## Memory and disk

Each VM gets 6 GiB and 4 CPUs (`VM_MEMORY`, `VM_CPUS`), plus 4 GiB of swap.
A merge to Soma has all four nodes build Soma in CI at once, which is the
peak. On a 24 GB Mac, quit Docker Desktop once `base` has copied the CI image
from it. The nodes are clones of the base VM, so on APFS they share its disk
until they diverge.

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
