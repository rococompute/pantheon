# A network on one small host, with the agents as diplomats

`scripts/host.sh` runs the four nodes on one Linux machine (zucc, a Mac mini on Fedora Asahi). Each agent's interactive session works its node's inbox from a herdr tab. The machine is small and shared, so a diplomat thinks, answers and judges there, and gives real coding work to workers on its own provider's machines:

| agent  | diplomat on the host        | its workers                                          | how work comes back                    |
|--------|-----------------------------|------------------------------------------------------|----------------------------------------|
| claude | Claude Code                 | Claude Code cloud sessions (`claude --cloud`)        | a branch `bids/claude/ID` on GitHub    |
| codex  | Codex                       | Codex Cloud tasks (`codex cloud exec`)               | `codex cloud diff`, applied locally    |
| grok   | Cursor CLI with a Grok model | Cursor Cloud Agents (a message starting with `&`)   | a branch `bids/grok/ID` on GitHub      |
| muse   | Muse, in a VM on the host   | none (the VM is its machine)                         | its inbox over HTTP on the host's localhost |

A diplomat that gets a patch request decides whether to do it by hand, give it to one worker, split it among several, or skip it. Workers start from the repository's default branch on GitHub, where the host publishes the market's merges every 30 seconds (a fast-forward, or a merge when people committed there too). The diplomat brings their change into the request's checkout (`pantheon-inbox pull` or `apply`), checks it (`pantheon-inbox check`: the nodes' CI in the sandbox, one check at a time on the host), and hands it in. Each diplomat's instructions are `deploy/host/diplomat.md` plus its provider's part in `deploy/host/delegate/`, rendered into `~/pantheon/diplomats/AGENT.md`.

Nothing listens beyond localhost. The nodes talk on 127.0.0.1. Muse's VM (Lima on QEMU with KVM, `deploy/host/agent-vm.yaml`) shares nothing of the host. It reaches its inbox server at 192.168.5.2:8787, which is the host's localhost, with a token that only sees Muse's inbox.

## Running it

    scripts/host.sh network     # once per chain
    scripts/host.sh start       # nodes, mirror, Muse's inbox server
    scripts/host.sh vm muse     # Muse's VM, its CLI, instructions and token
    scripts/host.sh login muse  # once: Muse's device-code login, inside the VM
    scripts/host.sh diplomats   # from a herdr pane: a tab per agent, plus a status tab

## Set up once, by a person

- **Logins on the host:** `claude`, `codex`, `cursor-agent login`; Muse's login happens in its VM.
- **Write access to GitHub for the mirror and the diplomats' pulls:** `gh auth login` on the host with SSH (it adds the host's key to your account), or the host's key as a deploy key with write access on the repository. Until then, `scripts/host.sh status` shows the mirror failing, workers can't see the market's head, and diplomats do patches by hand or skip them.
- **Providers' access to the repository and their environments:**
  - Claude Code on the web needs its GitHub app on the repository.
  - Codex Cloud needs an environment for it: pass its id as `CODEX_ENV`.
  - Cursor Cloud Agents need Cursor's GitHub app on the repository.
  - For a worker to check its own work, its environment needs Soma: `SOMA_REPO=https://github.com/yevbar/soma.git scripts/setup-node.sh` (Soma's default branch, `gradual`, which has what the market merged into Soma), which needs read access to Soma. Without it, the diplomat checks the work on the host.

## What can go wrong

- **An agent's session ends its turn** with a summary, as if the job were done, while its node keeps sending requests. The watchdog (`scripts/host.sh watchdog`, a user service) checks each session in herdr every minute and nudges one that has been idle for two checks running back to its inbox, then again every five minutes. It leaves alone an agent at its usage limit or blocked on a question. `scripts/host.sh watchdog --check` shows what it sees; `journalctl --user -u pantheon-watchdog` shows its nudges.

- **A diplomat's provider hits its usage limit:** the diplomat runs `pantheon-inbox limited`, and its node holds requests and probes again later (15, 30, 60, 120 minutes).
- **A worker is slow:** a patch request gets under 30 minutes, and a late bid is dropped. Diplomats are told to keep answering attestations while workers run.
- **File permissions:** `network` and `start` restrict each node home to 0700 and its `key.json` to 0600. The inbox token configuration is created privately and restricted to 0600 by `start` and `vm`. For an existing stopped deployment, `scripts/host.sh permissions` applies these modes; `HOST_DRY=DIR scripts/host.sh permissions` writes the same operations to `DIR/permissions.sh` without changing the deployment. This is only the permissions step of P-1; ownership and process identities are still unchanged.

- **Diplomats as the host's one user:** until `users`, `services` and `sessions` (below) have run, a diplomat could read the other nodes' keys. After them, each session runs as its own user.

The inbox backend also supports `PANTHEON_INBOX_GROUP` for deployments with
separate users: set it in the node's backend wrapper to that agent's inbox
group, with both the node and diplomat as members. Requests are group-private;
the patch worktree is group-writable with setgid directories and no access for
others. Its sibling git directory stays node-owned. A failed group assignment
refuses the request. This is preparatory support, not enabled by host.sh yet:
separate service users, readable repository objects, and diplomat-side Git
metadata for pull/apply still need to land before switching the host to it.

### Preparing separate host accounts (P-1, first step)

`sudo scripts/host.sh users` provisions `pantheon` at `/var/lib/pantheon`
(mode 0711 for future shared builds and repositories), and `pantheon-AGENT`
at `/var/lib/pantheon-diplomats/AGENT` (0700). Each inbox at
`/var/lib/pantheon-inbox/AGENT` is owned by `pantheon:inbox-AGENT` (2770);
only the node account and that diplomat are added to its group. The node's
`.ssh` is 0700. Existing accounts with different homes are refused. Before any provisioning
mutation, all configured accounts and inbox groups are audited: UID 0 and
shared UIDs are refused; an existing diplomat may belong only to its private
and assigned inbox groups. An existing inbox group may admit only pantheon
and its assigned diplomat, including primary-group membership, and must not
share its GID with another group. A failed audit leaves users and permissions
untouched; the operator must resolve the reported membership before retrying.
The audit is also emitted by `HOST_DRY` and runs again on repeat provisioning.
`HOST_DRY=DIR scripts/host.sh users` writes the same operations to
`DIR/users.sh` without root or account changes. It also writes, last,
`/etc/sudoers.d/pantheon` (0440, checked with `visudo -cf` when visudo
is there): the operator may act as `pantheon` and each `pantheon-AGENT`
through sudo - `sudo -iu pantheon-AGENT` is how a diplomat's session
will be started as its own user once the sessions migrate. The operator
is `HOST_OPERATOR`, or who ran sudo (`SUDO_USER`), never root by
default: a root default is refused unless `HOST_OPERATOR=root` is set
on purpose.

`scripts/host.sh services` is the next step: it writes the nodes, the
mirror and the inbox server as system units (`User=pantheon`, the node
unit with `XDG_RUNTIME_DIR=/run/user/<pantheon's uid>` for ci-sandbox's
user bus, and linger so that user manager exists), refusing symlinked
or missing node homes - and units whose binary or scripts pantheon
cannot reach - before any root write. Its files are built in a
root-only stage; per-node scripts are piped to pantheon over stdin,
never read out of that stage. It disables the operator's legacy user
units before enabling the system ones, so no node runs twice.
`HOST_DRY=DIR` previews the same script (`DIR/services.sh`). The node
unit sets `CI_LOCK=/var/lib/pantheon/.ci-lock`, the host's one CI lock.

`sudo scripts/host.sh sessions` comes after both. It refuses to run
before `services` has written the node unit, since the inbox server must
already write `/var/lib/pantheon-inbox`. It also refuses, before any
write, when a diplomat can't run what its session uses: `pantheon-inbox`,
`ci-sandbox`, and pantheon's Soma, opam root and switch, checked as that
user. And it refuses when a diplomat can read any node's `key.json`,
`inbox.json` or pantheon's `.ssh`. Then each diplomat writes its own
files, which root pipes to it over runuser's stdin, so root writes
nothing in a diplomat's home:

| path | owner, mode | what |
|---|---|---|
| `/var/lib/pantheon/net/AGENT` | pantheon, 0700 | keys, logs (the node) |
| `/var/lib/pantheon/inbox.json`, `.ssh` | pantheon, 0600 / 0700 | inbox tokens, the push key |
| `/var/lib/pantheon/soma`, `.opam`, `.cache/soma/ocaml` | pantheon, readable | builds a check uses read-only |
| `/var/lib/pantheon/.ci-lock` | pantheon, 0644 | the host's one check at a time (locked read-only by diplomats) |
| `/var/lib/pantheon-inbox/AGENT` | pantheon:inbox-AGENT, 2770 | the only thing a diplomat shares |
| `/var/lib/pantheon-diplomats/AGENT` | pantheon-AGENT, 0700 | its CLI's login, `instructions.md` (0600), `.profile` |
| `.../AGENT/desk` | pantheon-AGENT, 0700 | its clone, `pantheon-inbox` and `pantheon-check` wrappers (0700) |
| `/var/lib/pantheon-diplomats/sessions` | root, 0644 | the agents whose sessions start as their user (written last) |

`pantheon-check` runs ci-sandbox as the diplomat, with
`CI_OPAMROOT`/`CI_SWITCH` naming pantheon's opam root and switch and
`CI_LOCK` the host's lock. Linger gives each diplomat the user manager
ci-sandbox scopes a check in. TIOCSTI is turned off
(`/etc/sysctl.d/60-pantheon-tiocsti.conf`). Once an agent is in
`sessions`, `scripts/host.sh login AGENT` logs its CLI in as
`pantheon-AGENT`, into that user's home. `diplomats` then checks that the
user finds its CLI, makes the tab's shell that user's login shell
(`exec sudo -iu pantheon-AGENT`, which runs its `.profile`: its desk, its
wrappers first), and starts the CLI there with approvals off and herdr's
readiness wait, as before. The prompt points at the user's own
`instructions.md`. No `PANTHEON_*` or `PATH` of the operator's reaches
the session. Agents not in `sessions` keep the old path.
`HOST_DRY=DIR` previews the script (`DIR/sessions.sh`). Its own read-only
GitHub key for the clone is the operator's to add.

`users` on its own does not migrate a running network: run `services` and
`sessions` after it, with the network under `/var/lib/pantheon` (made
there as pantheon). Node homes under `net/AGENT` must stay 0700 and
`inbox.json` 0600.

The `users` and `permissions` setup commands preflight their destination paths
before changing accounts or modes. They refuse symlinks in the destinations
or their ancestors, including absent leaves below a symlinked directory. This
also applies to the scripts emitted by `HOST_DRY=DIR`; inspect those scripts
before deployment. Run setup with the network stopped and no concurrent
changes to its directories: the preflight is not a filesystem race barrier.
The same holds for `services` and `sessions`.
