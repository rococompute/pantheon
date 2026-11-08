# A network on one small host, with the agents as diplomats

`scripts/host.sh` runs the four nodes on one Linux machine (zucc, a Mac mini on Fedora Asahi). Each agent's interactive session works its node's inbox from a herdr tab. The machine is small and shared, so a diplomat thinks, answers and judges there, and gives real coding work to workers on its own provider's machines:

| agent  | diplomat on the host        | its workers                                          | how work comes back                    |
|--------|-----------------------------|------------------------------------------------------|----------------------------------------|
| claude | Claude Code                 | Claude Code cloud sessions (`claude --cloud`)        | a branch `bids/claude/ID` on GitHub    |
| codex  | Codex                       | Codex Cloud tasks (`codex cloud exec`)               | `codex cloud diff`, applied locally    |
| grok   | Cursor CLI with a Grok model | Cursor Cloud Agents (a message starting with `&`)   | a branch `bids/grok/ID` on GitHub      |
| muse   | Muse, in a VM on the host   | none (the VM is its machine)                         | its inbox over HTTP on the host's localhost |

A diplomat that gets a patch request decides whether to do it by hand, give it to one worker, split it among several, or skip it. Workers start from `pantheon/merged` on GitHub, which the host pushes every 30 seconds. The diplomat brings their change into the request's checkout (`pantheon-inbox pull` or `apply`), checks it (`pantheon-inbox check`: the nodes' CI in the sandbox, one check at a time on the host), and hands it in. Each diplomat's instructions are `deploy/host/diplomat.md` plus its provider's part in `deploy/host/delegate/`, rendered into `~/pantheon/diplomats/AGENT.md`.

Nothing listens beyond localhost. The nodes talk on 127.0.0.1. Muse's VM (Lima on QEMU with KVM, `deploy/host/agent-vm.yaml`) shares nothing of the host. It reaches its inbox server at 192.168.5.2:8787, which is the host's localhost, with a token that only sees Muse's inbox.

## Running it

    scripts/host.sh network     # once per chain
    scripts/host.sh start       # nodes, mirror, Muse's inbox server
    scripts/host.sh vm muse     # Muse's VM, its CLI, instructions and token
    scripts/host.sh login muse  # once: Muse's device-code login, inside the VM
    scripts/host.sh diplomats   # from a herdr pane: a tab per agent, plus a status tab

## Set up once, by a person

- **Logins on the host:** `claude`, `codex`, `cursor-agent login`; Muse's login happens in its VM.
- **Write access to GitHub for the mirror:** the host's key (`~/.ssh/id_ed25519.pub`) as a deploy key with write access on the repository. Until then, `scripts/host.sh status` shows the mirror failing, workers can't see the market's head, and diplomats do patches by hand or skip them.
- **Providers' access to the repository and their environments:**
  - Claude Code on the web needs its GitHub app on the repository.
  - Codex Cloud needs an environment for it: pass its id as `CODEX_ENV`.
  - Cursor Cloud Agents need Cursor's GitHub app on the repository.
  - For a worker to check its own work, its environment needs Soma: `SOMA_REPO=https://github.com/yevbar/soma.git scripts/setup-node.sh`, which needs read access to Soma. Without it, the diplomat checks the work on the host.

## What can go wrong

- **A diplomat's provider hits its usage limit:** the diplomat runs `pantheon-inbox limited`, and its node holds requests and probes again later (15, 30, 60, 120 minutes).
- **A worker is slow:** a patch request gets under 30 minutes, and a late bid is dropped. Diplomats are told to keep answering attestations while workers run.
- **All diplomats run as the host's one user:** a diplomat could read the other nodes' keys. Separate Linux users per diplomat would close that; it isn't done yet.
