# cmux: a Pantheon network as a cmux workspace

`pantheon-cmux` runs a network (a directory made by `pantheon init`) as one
[cmux](https://cmux.com) workspace on a Mac.

- **Panes:** each agent gets a pane. Its node runs there in the foreground,
  and its output also goes to `NET/AGENT/node.log`.
- **Diplomats:** an agent with a diplomat gets a second tab in its pane,
  running the CLI of its provider (Claude Code, codex, the Cursor CLI, or
  Muse), which works the node's inbox.
- **Sidebar:** shows each node's height, term and leader.
- **Watchdog:** nudges a diplomat that stopped working its inbox, and sends
  you a notification when one waits on you.

```
pantheon-cmux up NET [--diplomats "A B"] [--backends A=B,...] [--yolo] [-- NODE ARGS...]
pantheon-cmux status NET          # the sidebar's loop (up starts it)
pantheon-cmux watchdog NET [--check|--once]
pantheon-cmux down NET            # close the workspace: nodes and sessions stop
```

`pantheon-cmux` alone prints its usage and settings.

## Try it

Start with scripted nodes, which need no model. Run this from a cmux
terminal, or anywhere while cmux.app is open:

```bash
./main.exe init .net --repo calc=.calc --block-ms 300 --param term_blocks=40 --param max_merges=1
printf -- '- add a sub command\n' > .net/goal.txt
integrations/cmux/pantheon-cmux up .net -- --goal .net/goal.txt --bid-window 8
```

That gives a workspace named "pantheon: .net" with four panes. Each pane has
a `AGENT node` tab, and the first pane also has `status` (the sidebar's
loop). The sidebar shows `pantheon.AGENT  hN tN · leader X`. Close it all
with `integrations/cmux/pantheon-cmux down .net`.

To make one agent a diplomat, add `--diplomats claude`. Claude's node then
asks through `NET/.cmux/claude/inbox`, and a `claude diplomat` tab starts
Claude Code. That tab is told to read `NET/.cmux/claude/desk/instructions.md`
(from `integrations/cmux/diplomat.md`). A `watchdog` tab joins `status`.

## What it keeps

All its state is in `NET/.cmux/`:

- `workspace`: the workspace's id.
- `AGENT/node.sh`: the node's command. It runs from the directory `up` ran
  in, so relative `--goal` paths work as they do for `pantheon up`.
- `AGENT/node-surface`, `AGENT/surface`: the node's tab and the diplomat's
  tab.
- For a diplomat:
  - `AGENT/backend.sh`: the node's backend, which runs
    `scripts/bidder-inbox.sh` on the diplomat's inbox.
  - `AGENT/inbox/`: the inbox. It's put in your group, because
    `bidder-inbox.sh` makes each request setgid, and under macOS's `/tmp`
    the group would be `wheel`, which you're not in.
  - `AGENT/desk/`: the session's working directory, holding the
    `pantheon-inbox` wrapper and `instructions.md`.
  - `AGENT/session.sh`: the command that starts the session.

## The watchdog

The watchdog reads each diplomat's state from `cmux current --json`, which
cmux's hooks for Claude Code, codex, Grok, Muse and Cursor fill in. It
matches a session by its tab's id.

| State | What the watchdog does |
|---|---|
| `idle`, `done`, `completed` | After two passes in this state, it pastes a message telling the agent to go back to its inbox, and does it again every five passes. |
| `needs_input`, `blocked`, `waiting` | A person's call: an approval or a question. It sends one `cmux notify`, and nothing more. |
| `working`, or no state (a CLI without hooks) | Leaves it alone. |
| Node holding requests for a usage limit | Leaves it alone. |

`--check` shows what it sees without nudging anyone. `--once` runs a single
pass, nudges included, for a test or a cron job.

## Isolation, and what's next

Every pane runs as you, and the node homes in `NET` hold the agents' keys.
Without `--yolo`, each CLI asks before it runs a command: you answer in its
tab, and the watchdog's notification tells you when one is waiting. With
`--yolo`, approvals are off and nothing stands between a diplomat and every
node's key. Use it only on a network whose keys and repositories don't
matter (docs/SAFETY.md).

The next step is isolation like the Linux host's: each diplomat in its own
Lima VM, the way `scripts/host.sh vm` runs Muse. The diplomat's tab would run
`limactl shell pantheon-AGENT …`, and its inbox would go over
`scripts/inbox-http.py` with a token (`INBOX_URL` in its backend), so the VM
never sees `NET`.

Other limits:

- One machine only: every node of `NET` runs here. A network spread across
  machines (docs/NETWORK.md) would need a workspace per machine.
- The panes are a grid of two rows, which gets crowded beyond about eight
  agents.
- `up` refuses while any of `NET`'s nodes run outside cmux, for example
  after `pantheon up`.
- Its nodes stop with their terminals. `down` waits up to 10 seconds, then
  terminates any node still running.
