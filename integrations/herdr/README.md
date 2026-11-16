# herdr: a network's diplomats as herdr tabs

**Status: reference, and it may not work right now.** This is how the Linux
host ran its diplomats during the first dogfood nights (docs/HOST.md,
docs/DOGFOOD-REPORT.md). Nobody has run it since the network went
laptop-only, herdr's CLI may have changed since, and the only test of it
here (`test/host-diplomat-required.sh`) uses a stub of herdr, not herdr
itself. Use it as a model for another terminal multiplexer: for cmux on a
Mac, `integrations/cmux/` follows the same plan.

## What it does

`herdr.sh` is sourced by `scripts/host.sh`. It isn't a command of its own,
and its functions use host.sh's settings and helpers.

- `scripts/host.sh diplomats`, run from a herdr pane: adds tabs to that
  pane's herdr workspace.
  - A `status` tab runs `scripts/host.sh status` every 20 seconds.
  - Each agent gets a tab. The tab becomes the agent's own login shell
    (`sudo -iu pantheon-AGENT`), and `herdr agent start` launches the
    agent's CLI there with approvals off: Claude Code, codex, or the Cursor
    CLI for grok. The agent is then told to read its instructions
    (`/var/lib/pantheon-diplomats/AGENT/instructions.md`, rendered from
    `deploy/host/diplomat.md`). From then on the agent works its node's
    inbox: `pantheon-inbox wait`, then `reply`, `done` or `skip`.
  - An agent that works from a VM (Muse) gets a tab named `AGENT (vm)`
    running `limactl shell` into its VM.
- `scripts/host.sh watchdog` installs a systemd user unit that runs
  `scripts/host.sh watchdog-loop`. Every minute it reads each agent's state
  from `herdr agent list` (or, for a VM agent, its screen). An agent idle for
  two checks in a row gets a message telling it to go back to its inbox,
  and then another every five minutes while it stays idle. It leaves alone
  an agent whose node is holding requests for a usage limit, one
  blocked on a person's question, and every agent of a market that
  finished (`finish=1`), whose nodes stopped: no request will come.

## What it relies on

- **Isolation by Unix user.** A diplomat starts only once
  `scripts/host.sh users`, `services` and `sessions` have made its account,
  and it never falls back to the operator's account (that's what
  `test/host-diplomat-required.sh` checks). Each diplomat shares only its
  inbox with the nodes, and the node keys are the `pantheon` user's.
- **Linux:** systemd user units, `runuser`, sudoers, and Lima for the VM
  agents.
- **herdr's CLI:** `herdr tab create`, `pane run`, `pane read`,
  `pane send-text`, `pane send-keys`, `agent start`, `agent prompt` and
  `agent list`, plus the `HERDR_ENV` and `HERDR_WORKSPACE_ID` variables.

## Limits

- One herdr workspace for one network on one host. No layout is chosen:
  it's one tab per agent.
- The watchdog's idle check is a heuristic. herdr's agent status can say
  `idle` while a session waits on a long command. For a VM agent the check
  is a screen grep for "esc to interrupt", which breaks whenever the CLI
  changes that text.
- Nudges are typed into the session. A session that keeps the text in its
  input box gets a second Enter, and nothing more.
- The CLIs run with approvals off. That is safe only because of the
  per-user isolation above. Don't port this to a setup that runs every
  session as one user without reading docs/SAFETY.md first.
