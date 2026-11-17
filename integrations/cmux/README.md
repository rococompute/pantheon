# cmux: a Pantheon network as a cmux workspace

`pantheon-cmux` runs a network (a directory made by `pantheon init`) as one
[cmux](https://cmux.com) workspace on a Mac.

- **Left half: the network.** A live markdown view of `NET/.cmux/plan.md`,
  which the watchdog rewrites when it changes: the goal's opening paragraph
  under **Market
  (X leader)**, X the term's leader (**Market** while one is drawn, **Done**
  once a finishing market finished; in a finishing market whose leaders have
  begun to say there are no more tasks, **Market (X leader, N/K to done)**, N
  of the roster's K agents having said so), with the remaining goal text in a
  collapsed **Details** section, and each repository's `.plan`
  at the market's head, every item led by its status (✅ explicitly marked done,
  🔧 work merged with the plan item still open, ⏳ being bid on,
  🟡 not picked up yet; dropped ones struck through), then the last 20
  **Bids**. A bid is a details block: in its summary its outcome (🟢 merged,
  🟡 pending, 🔴 rejected, ⚪ cleared or withdrawn) and its title, the
  leader's for a merge or a rejection (what it does for the goal, or why not),
  else its bidder's; inside, its bidder's title and note and the leader's
  reason. Internal task records stay hidden; their activity is reflected in
  the goal and plan items. Each term's leader
  is in the `watchdog` tab beside it.
- **Right half: a pane per agent,** in a grid of two rows. An agent with a
  diplomat has two tabs there: its diplomat's session, the CLI of its
  provider (Claude Code, codex, Grok Build, or Muse) working the node's inbox,
  then its node (`AGENT node`). An agent without one has its node. A node's
  output also goes to `NET/AGENT/node.log`.
- **Its name:** the market's title, as the plan heads it: **Market**, then
  **Market (X leader)**, **Market (X leader, N/K to done)** as a finishing
  market's leaders say there are no more tasks, then **Done**. Nothing else
  goes in the sidebar.
- **Watchdog:** keeps the name and the plan, says each term's leader,
  nudges a diplomat that stopped working its inbox, and sends you a
  notification when one waits on you.
- **A finishing market** (`pantheon init ... --param finish=1`): when it
  finishes, its nodes stop on their own, the plan view heads its goal and the
  workspace is named **Done**, each diplomat's inbox wait tells it to stop,
  and you get a notification. `down` closes the workspace.

```
pantheon-cmux up NET [--diplomats "A B"] [--backends A=B,...] [--layout plan|grid] [-- NODE ARGS...]
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

That gives a workspace named **Market** (then **Market (X leader)**): on the left the plan, with a
`watchdog` tab beside it (it keeps the name and the plan), and on the right
a pane for each of `claude`, `codex`, `grok` and `muse` (their nodes). Close it all with
`integrations/cmux/pantheon-cmux down .net`.

To make one agent a diplomat, add `--diplomats claude`. Claude's node then
asks through `NET/.cmux/claude/inbox`, the `claude` tab starts Claude Code,
and Claude's node moves to a `claude node` tab beside it, in Claude's pane.
Claude Code is told to read `NET/.cmux/claude/desk/instructions.md` (from
`integrations/cmux/diplomat.md`), and the `watchdog` tab watches its session too.

`--layout grid` gives the earlier layout instead: a pane per agent in a grid
of two rows, each with an `AGENT node` tab and, for a diplomat, an
`AGENT diplomat` tab, and no plan view.

## The run's record

Every run is recorded by default, outside `NET`, so removing `NET` loses
nothing: `~/.pantheon/runs/NAME-YYYYMMDD-HHMMSS/` (or under `PANTHEON_RUNS`).
It holds `run.txt` (the network, when, the diplomats, the node arguments),
the goal, `leaders.log`, `plan.md`, and for each node its `blocks.log`
(every signed transaction: each task posted and by whom, each bid with its
title, note and patch, picks, merges with the leader's title, rejections and
their reasons, closes, finish votes), `status.txt`, `node.log` and
`genesis.json`, never `key.json`. Once the market finishes or goes down,
`repos/NAME.bundle` holds each repository as the market left it (`git clone
NAME.bundle`). `up` makes it and says where, the watchdog keeps it current,
and `down` finishes it.

## What it keeps

All its state is in `NET/.cmux/`:

- `workspace`: the workspace's id.
- `plan.md`: what the plan view shows. `goal` holds the goal file's path.
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

The `watchdog` tab runs with or without diplomats. Every 10 seconds it sets
names the workspace for the market, rewrites the plan view when it changed, and
says each new term's leader; once a finishing market finished, it tells the
diplomats and you, and stops. Once a minute it watches the diplomats.

It reads each diplomat's state from `cmux current --json`, which
cmux's hooks for Claude Code, codex, Grok, Muse and Cursor fill in. It
matches a session by its tab's id.

| State | What the watchdog does |
|---|---|
| `idle`, `done`, `completed` | Nudges only when the same live, unanswered inbox request persists for two idle passes, then every five passes. Empty inboxes and active background waits are left alone. |
| `needs_input`, `blocked`, `waiting` | A person's call: an approval or a question. It sends one `cmux notify`, and nothing more. |
| `working`, or no state (a CLI without hooks) | Leaves it alone. |
| Node holding requests for a usage limit | Leaves it alone. |
| The market finished (`finish=1`) | Nudges no one: no request will come. The watchdog's loop ends. |

`pantheon-inbox wait` publishes a lease with its process ID and deadline,
and removes it when the wait ends or is cancelled. The watchdog verifies both,
so stale files cannot indefinitely hide a stopped diplomat. This also handles
Muse background waits whose cmux lifecycle state continues to say `idle`.
Answered, expired and incomplete requests do not count as pending work.

It also says each term's leader as the term starts (`term 4: claude leads
(seen at h218)`), from the `history` line of `status.txt`, which lists the last
8 terms' leaders, so a term shorter than a pass is still said. It keeps them in
`NET/.cmux/leaders.log`, a line a term: `TERM LEADER HEIGHT TIME`, the height
and time it saw the term at.

`--check` shows what it sees without nudging anyone. `--once` runs a single
pass, nudges included, for a test or a cron job.

## Isolation, and what's next

Every pane runs as you, and the node homes in `NET` hold the agents' keys.
Every diplomat runs without asking: `claude --dangerously-skip-permissions`,
`codex --dangerously-bypass-approvals-and-sandbox`, `grok --always-approve`
and `muse --yolo` (`--yolo` is still accepted, and changes nothing). So
nothing stands between a diplomat and every node's key. Run diplomats only
on a network whose keys and repositories don't matter (docs/SAFETY.md).

The next step is isolation like the Linux host's: each diplomat in its own
Lima VM, the way `scripts/host.sh vm` runs Muse. The diplomat's tab would run
`limactl shell pantheon-AGENT …`, and its inbox would go over
`scripts/inbox-http.py` with a token (`INBOX_URL` in its backend), so the VM
never sees `NET`.

Other limits:

- One machine only: every node of `NET` runs here. A network spread across
  machines (docs/NETWORK.md) would need a workspace per machine.
- The plan view shows a `.plan` as committed at the head of one node's
  checkout (the first agent's): an uncommitted edit there doesn't show, and
  the node cleans it away on its next merge. To change the plan, commit it
  the way the market does (docs/PLAN.md).
- With `--layout grid`, the panes get crowded beyond about eight agents.
- `up` refuses while any of `NET`'s nodes run outside cmux, for example
  after `pantheon up`.
- Its nodes stop with their terminals. `down` waits up to 10 seconds, then
  terminates any node still running.
