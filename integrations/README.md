# Integrations: a network in a terminal multiplexer, or on its own

`standalone/` runs a network with no multiplexer: its nodes only coordinate
the market, and its agents answer over HTTP from wherever they run (remote,
or each in a container), with its nodes as binaries or unikernels. Its
README says how. The rest of this page is about the multiplexers.

Each multiplexer integration runs a Pantheon network inside it, with
one workspace per network. Every agent gets a place there (a pane, or in
cmux's default layout a tab beside the market's plan): its node runs there,
and if the agent has a diplomat, the diplomat's interactive session runs
there too. A diplomat is a coding agent's CLI working its node's inbox
(`scripts/pantheon-inbox`, fed by `scripts/bidder-inbox.sh`).

| Folder | Where it runs | Status |
|---|---|---|
| [`cmux/`](cmux/README.md) | A Mac with [cmux](https://cmux.com) | Works. Tested with `test/integration-cmux.sh` against a stub of cmux, and by hand in cmux with scripted nodes and a stub diplomat. |
| [`standalone/`](standalone/README.md) | Any machine, no multiplexer: nodes as binaries or (a Mac) unikernels, agents remote over HTTP or each in a Docker container | Works. Tested with `test/integration-standalone.sh` (real nodes, a stub of docker) and `test/integration-standalone-image.sh` (a real unikernel, on a Mac with Soma's MirageOS switch). |
| [`herdr/`](herdr/README.md) | The Linux host (`scripts/host.sh`) | Reference: not run since the network went laptop-only, and it may not work right now. |

## What every integration does

1. **Make the panes.** One workspace per network, and one pane per agent in
   it. The node runs in the pane, its output on screen. An agent with a
   diplomat gets a second tab, in which its CLI is told to read its
   instructions and work its inbox.
2. **Wire the inbox.** Each diplomat has its own inbox, separate from the
   node's own `NET/AGENT/inbox`, which holds transactions. Its node's backend
   (`cmd:` + a script that sets `PANTHEON_INBOX`) writes requests into it.
   The diplomat's wrapper `pantheon-inbox` reads that same inbox. A wrapper
   is needed because some CLIs drop environment variables before running
   commands.
3. **Show the chain.** A loop reads each `NET/AGENT/status.txt` and shows
   height, term and leader where the multiplexer shows status.
4. **Watch the sessions.** A coding agent's session sometimes ends its turn
   while its node keeps sending requests. A watchdog reads each session's
   state from the multiplexer and nudges one that has been idle for two
   passes, then again every five while it stays idle. It leaves alone an
   agent whose node is holding requests for a usage limit, and one that
   waits on a person.

To add another multiplexer, copy `cmux/pantheon-cmux` and swap its calls to
`cmux` for the other tool's: making a workspace, a split and a tab, renaming
a tab, setting status, reading a session's state, and pasting a message into
a session. Then copy `test/integration-cmux.sh`, which tests against a stub
of the CLI, so the new integration is tested without the multiplexer.

## Isolation

The keys in `NET/AGENT/key.json` are each agent's identity. On the Linux
host, each diplomat runs as its own Unix user, and only its inbox is
shared. On a laptop, every pane runs as you. Read docs/SAFETY.md before
turning a diplomat's approvals off on a network whose keys or repositories
matter.
