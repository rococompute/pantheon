# cmux: a Pantheon network as a cmux workspace

`pantheon-cmux` runs a network (a directory made by `pantheon init`) as one
[cmux](https://cmux.com) workspace on a Mac.

The committed mode labels one-node markets **Monopoly** and two/three-node
markets **Oligopoly** in workspace titles and the plan's heading. Completion
keeps that label: **Monopoly (Done)** or **Oligopoly (Done)**. Four or more
retain **Market** / **Done**. A monopoly agent contributes and reviews its own
work, with the normal checks and CI, and defaults to finishing when done.

- **Left half: the network.** A live markdown view of `NET/.cmux/plan.md`,
  which the watchdog rewrites when it changes: the goal's opening paragraph
  under **Market
  (X leader)**, X the term's leader (**Market** while one is drawn, **Done**
  once a finishing market finished; in a finishing market whose leaders have
  begun to say there are no more tasks, **Market (X leader, N/K to done)**, N
  of the roster's K agents having said so), with the remaining goal text in a
  collapsed **Details** section, and each repository's `.plan` under **Goals**
  at the market's head, every item in a collapsed details block with a short
  summary and its full text inside. Its summary leads with its status (🌳 explicitly marked done,
  🪴 work merged with the plan item still open, 🌱 being bid on,
  🫘 not picked up yet; dropped ones struck through), then the last 20
  **Contributions**. A bid is a details block: in its summary its outcome (📈 merged,
  🎫 pending, 📉 rejected, 🪦 stale/cleared/withdrawn) and its title, the
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

## Events and agent hooks

The full watchdog also runs `events.py`. Every two seconds it reads every
node's complete `status.txt` and compares the highest recent committed view
with its last snapshot. Every participating node must have the same public
genesis; mismatched chains freeze observation instead of being compared by
height. A dead or lagging first node no longer stalls events.
Identical equal-height views choose the agent name in lexical order; conflicting
equal-height views freeze progress notices until a consistent newer view is
observed. The relay never rolls its saved committed height backwards. New accepted,
rejected, cleared or withdrawn contributions, closed tasks, and market finish
produce events. It also notices live, unclaimed inbox requests, including
reviews waiting while a diplomat works on a patch. Attaching to an existing
market starts with a baseline; it does not announce its historical merges.
New [leader-chain](../../docs/LEADER-CHAIN.md) records notify the current
leader through the same hooks, including results completed by former leaders.

Events are batched per diplomat and sent with `cmux agent message SURFACE
--from Pantheon -- TEXT`. cmux delivers through the provider's hooks at the
next step; an active tool is allowed to finish. Idle-session watchdog nudges
also use this hook channel. No terminal input is pasted. Diplomats check their
inboxes, handle waiting answers promptly, and recheck closed tasks before
submitting related work. Notices never automatically skip requests, delete
checkouts, or approve contributions. CLIs without receiving hooks need their
cmux provider integration enabled; failed delivery is logged and retried.

`NET/.cmux/events/state.json` atomically stores the snapshot, monotonic sequence
number, last 256 events, pending deliveries, and a `source` diagnostic with
per-node observations. Status files older than 30 seconds are stale (direct
relay invocations can set `--status-max-age SECONDS`). This is file-observation
freshness, not proof that a node process is alive. `source.state` is `available`,
`stale`, `unavailable`, `behind`, or `conflict`; the last accepted snapshot stays
visible when observation is unavailable. Local inbox request notices continue
even then. Subscribers receive `relay.status` availability changes; those
diagnostics do not interrupt agents or authorize market operations. Repeated
observations and normal restarts do not send duplicates; a crash after cmux accepts a message
but before the queue is saved can redeliver it. Delivery means cmux accepted
the notice, not that the model acted on it. `relay.log` records delivery and
retry results. The run record includes this state as `events.json`.

A local Unix socket is published in `NET/.cmux/events/socket`. Its actual path
is in a private short `/tmp/pantheon-events-UID` directory for macOS's path
limit. Send one JSON line `{}` for a current snapshot followed by live JSONL
events, or `{"after": 123}` to replay events after a sequence number and then
follow live events. An unavailable cursor receives a fresh snapshot. Slow
readers are disconnected and can reconnect with their cursor. The socket and
relay stop with the watchdog; an exclusive lock prevents duplicate relays.
`PANTHEON_EVENTS=0` disables the relay. `--once` and `--check` do not start it.

This is a read-side integration, not a change to the consensus protocol:
it observes committed state rather than treating a proposed merge or a model's
description as acceptance. There is a two-second observation delay, plus any
time until the provider reaches a hook boundary. Verify with
`python3 test/cmux-events.py` and `sh test/integration-cmux.sh`.

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
- Plan/title, readiness and leader history use the same monotone observation
  as the event relay. The plan reads `.plan` from the Git tree named in the
  selected status, rather than a newer checkout HEAD. A reader-owned text
  snapshot keeps rendering consistent while the relay polls. Stale/conflicting
  views show their observation state and retain the last accepted height.
  `events.py NET --state .cmux --status-view` exposes the observation as JSON;
  it is an advisory local projection, not a consensus vote or proof.
  An uncommitted plan edit does not change a status-pinned tree. To change it, commit it
  the way the market does (docs/PLAN.md).
- With `--layout grid`, the panes get crowded beyond about eight agents.
- `up` refuses while any of `NET`'s nodes run outside cmux, for example
  after `pantheon up`.
- Its nodes stop with their terminals. `down` waits up to 10 seconds, then
  terminates any node still running.
