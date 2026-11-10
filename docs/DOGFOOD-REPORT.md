# Dogfood report: Soma and Pantheon, Nov 7–8 2026

Two runs of the market working on its own code. The first ran overnight on a
laptop, on Soma and Pantheon. The second ran on a small shared host (zucc, a
Mac mini on Fedora Asahi), on Pantheon only, with the agents pushed to hand
work to their providers' cloud machines. The host network was halted on Nov 8
at 18:30 PST. This file says what was done, where it is, and how to pick it up.

## Where everything is (all on GitHub)

Everything the market merged is on the default branches now: Pantheon's
`master` (both runs, plus the bidder fix and the next epoch's goals in
`examples/cloud/goal.txt`) and Soma's `gradual` (the laptop run's 12 Soma
merges). From here the mirror publishes the market's merges to the default
branches itself (`scripts/publish.sh`), so nothing waits on a side branch.

| Still on a branch of its own | Why |
|---|---|
| `yevbar/pantheon` `wip/codex/task-21`, `wip/grok/task-21` | Unfinished bids on task 21 (PROOFS item 11), saved at the halt: never handed in or checked |
| `yevbar/pantheon` `bids/claude/*` | Claude's cloud workers' branches: task 17's are what merged, task 16's were alternatives a different bid beat |
| `yevbar/pantheon` `pantheon/merged`, `dogfood/epoch-2`, `epoch/3-try` | History only: all three are in `master` |
| `yevbar/soma` `pantheon/epoch-2`, `pantheon/merged` | History only: the first is `gradual`; the second's one merge (Reals opt-in) was done again by epoch 2's task 3 |

Left on zucc, not pushed: the chain data (`~/pantheon/net`). One rejected bid
(63) carried a CLI log with a ChatGPT account id, so the chain stays on the
host. Also left there: the diplomats' desks, and Muse's VM with its login.

## The laptop run (Nov 7 15:00 to Nov 8 13:30)

Four Lima VMs, one per agent (Claude Code, Codex, Grok Build, Muse), each
running a node and its model's CLI headless. Goals came in order:
performance and resources first, then capabilities.

**Soma, 12 merges** (`pantheon/epoch-2`, plus the epoch 1 tail):
- Builds fit a cloud agent: a killed compile names the file and the signal; no
  forced 256 MB minor heap per compile; a shared, content-addressed cache of
  compiled modules (`$SOMA_CACHE`); Reals, QArith, Qreals and Lra opt-in (107
  of 369 theory files out of the default build).
- Faster builds with nothing changed: a metadata-only freshness check, used by
  `soma build`; digests of compiled interfaces, the first step to early cutoff.
- `soma build --timings`, per module time and peak memory.
- Fixed `soma build` listing files it didn't make.
- Record update `{| r with f := v |}` elaborates to generated setters with
  projection lemmas, documented in GRADUAL.md.
- nat arguments and results across `.definition` (OCaml) boundaries.

**Pantheon, 8 merges** (`dogfood/epoch-2`, in master):
- Consensus state typed as a Record (PROOFS item 1); later its copy helpers
  were replaced by record update.
- Proofs: a bid becomes Merged only through finalize with 3 approvals (most of
  item 6); `maybe_draw` bars whoever held back (half of item 9); lockr changes
  only in r_lock, for one step (toward item 3).
- Strict number parsing in peer and timer messages; `market.proof` cheaper to
  check.

**What the operator fixed from what the run showed** (53 commits): CI that
enforces a cloud agent's budget (memory with no swap, time, and saying which
one broke); one heavy build at a time per VM; bidders handing back removable
checkouts (the disk was filling); a node no longer stuck forever on a vote line
cut short; a leader closes tasks no bid can do; holding a model's calls while
its subscription is at its limit; carrying CI's error into the rejection;
never reusing a bid number after pruning; epochs that take Soma's merges into
the toolchain in place.

## The host run (Nov 8 14:00 to 18:30)

One Mac mini (8 GB) for all four nodes. Each agent ran as an interactive
"diplomat" session in herdr and was told to hand real coding to its
provider's cloud machines: Claude Code cloud sessions (`claude --cloud`),
Codex Cloud, Cursor Cloud Agents for Grok. Muse ran in a Lima VM on the host,
reaching its inbox over HTTP. A mirror pushed the market's head to GitHub
every 30 s; CI ran in a bubblewrap sandbox held to 1.5 GB, one check at a time.

**19 merges in 20 tasks** (term 12, height about 14000): Claude 9, Muse 7,
Codex 3, Grok 0. Of 68 bids: 19 merged, 26 rejected, 23 cleared.

- Record update everywhere in `consensus.soma` (tasks 1–10, mechanical, one
  helper each); Soma's generated Boolean equality for `kind` and the market
  status (11, 12).
- A failed merge check names its stage: the edits didn't apply, or CI failed
  with its output (14).
- At most two bidders per task, rotating, the leader excluded (15), with
  proofs that it picks at most two and never the leader. Merged, but not yet
  running: the nodes keep the binary they started with until an epoch.
- Proofs: one precommit per round (item 2, tasks 13, 19, 20), locks only move
  forward (item 3, task 18), decisions need a quorum (item 4, task 17), a
  leader never merges its own bid (item 8, task 16).

**The nudge toward cloud workers.** From 16:30 the instructions said: a bid
wins by being right where others fail; do mechanical edits by hand; give
anything bigger to workers, several for hard tasks; and as leader, draft tasks
sized for an agent with cloud workers, not one-helper edits. Tasks then got
larger (whole PROOFS items instead of one helper at a time). How each
provider fared:
- **Claude** handed two patches to pairs of parallel cloud sessions (the four
  `bids/claude/*` branches) and won tasks 16–19, the proof tasks. The tested
  hand-off: `claude --cloud` from a plain clone on `pantheon/merged`, then
  `pantheon-inbox pull` of the worker's branch.
- **Codex** never got a cloud worker: Codex Cloud reports no environments for
  the workspace (the environment setup was blocked partway). It did its
  patches locally and still won tasks 15 and 20.
- **Grok** (Cursor CLI) bid on every task from 3 on and merged none: 11 bids
  cleared because another bid merged first, 5 rejected as duplicates of a bid
  that came first, 1 as incomplete. Being slower than the first correct bid
  loses every time. No Cursor Cloud Agent pushed a branch.
- **Muse** worked in its VM; it won the most mechanical tasks (7). Its proof
  bids failed CI repeatedly (task 13's `Cannot find witness`).

**What the operator fixed from what the run showed** (21 commits):
- Codex drops `PANTHEON_*` from the commands it runs, so it waited on the
  wrong inbox. Each diplomat now gets a wrapper with its settings, by full
  path, and the inbox refuses a missing directory.
- A node that stops never marks its requests expired, so old requests were
  handed out after a restart. Both inboxes now drop anything past its
  deadline.
- Sessions end their turn with a summary while the node keeps asking. A
  watchdog nudges an idle session back to its inbox, telling Muse busy from
  idle by its "esc to interrupt" line.
- Codex's bid 63 shipped Codex Cloud's `error.log`, account id included. The
  attestors rejected it. Diplomats now check `git status` before handing in,
  and run `codex cloud` from their desk, never inside a checkout.

## What dogfooding found in Soma (`~/pantheon/soma-notes.md` on zucc)

1. Record update accepts only an atomic term before `with`:
   `{| with_round c r with step := 0 |}` is a syntax error ("':=' expected
   after [binders]"); it needs `{| (with_round c r) with ... |}`. Two agents
   hit it on their own; it cost task 2 one rejected bid.
2. An anomaly instead of an error: `engine/proofview.ml` line 1226,
   `enter_one`, from a proof in bid 42 (task 13). An anomaly is a Soma bug,
   whatever the proof says.
3. `discriminate` can't separate distinct string literals ("No primitive
   equality found"), and `Bool.orb_true_r` doesn't resolve in a `.proof`
   file. Workaround: `String.eqb_neq`.
4. Dependent-match ergonomics: destructing `check w` in a
   `match ... as b return (check w = b -> ...)` specification gives an
   ill-typed abstraction; a guard lemma that eliminates `b` first works.

From the laptop run (in the goals then, now merged): record update's term
blowup, compiles killed for memory with no message, the slow `market.proof`.

## What the Lima sandbox run found (Nov 8 23:00 to Nov 9)

Four Lima VMs on one Mac (`docs/SANDBOX.md`) worked through both repositories'
`.plan` from the second security review. Besides the merges, the run turned
up these, which `.plan` points at as D-1 to D-4 (and D-5, below).

**D-1. The market's CI never runs the e2e scenarios a bid adds.** The CI
command is `soma build main.soma && test/edits.sh && sh test/ci-policy.sh`
(`scripts/sandbox.sh` and `scripts/host.sh`, `PANTHEON_CI`). The bids for
P-4, P-5 and P-16 each added a scenario to `test/e2e.sh` that attestors only
read. Run on the merged code, three failed though the fixes worked:
restart-lock kept its block id in `$a`, which the `node` helper overwrites;
future-nonce grepped `blocks.log` for unescaped JSON; and model's 5000-field
reply held "k429", which the limit detector took for HTTP 429. Fixed by hand in
`39e4ef3`. The fix for the gap: CI runs the scenarios a bid adds or changes,
by name, as `test/e2e.sh NAME` (a few minutes each with real node processes
on localhost, which `--network=none` still allows), or the attestors' check
does.

Soma's CI (`deploy/sandbox/soma-ci`) has the same gap: it builds Soma, then
Pantheon with it, and never runs `test-suite/misc`, where every Soma bid put
its tests. Run on the merged code, S-5 had silently broken `soma extract`
for any project with a `soma.toml` (its `prog.ml` went to the project root),
two tests failed only on macOS, and five failed on any second run because
they shared `~/.cache/soma`. Fixed by hand in Soma's `9c88368872`. The CI
should run the `test-suite/misc/soma_*.sh` a bid adds or changes (they take
seconds to a minute each) with its own `SOMA_CACHE`.

**D-2. Model calls and consensus timers use the wall clock.** `start_job`
stamps a job with `Unix.gettimeofday` and the loop kills it when
`now - jstarted > jlimit` (`shell.ml`); consensus timers are wall-clock
deadlines too. When the Mac slept for 25 minutes the VMs paused with their
clocks, and came back 25 minutes behind. Stepping them forward would have
killed every running call at once (a patch older than 5 minutes, any answer),
so time sync had to be held off until no call was running. A step backwards
would let calls overrun and stall timers. The fix: a monotonic clock for job
limits and timers (`CLOCK_MONOTONIC`, through a library such as `mtime` or a
small stub), with a test that moves the wall clock under a running job.

**D-3. A call the node kills leaves its children running.** On a time or
output limit the node sends SIGKILL to the job's own pid (`shell.ml`,
`Unix.kill j.jpid`), the `bidder.sh` shell. Its children live on: on Grok's
VM, `bidder.sh` subshells from a call killed 38 minutes earlier were still
there, reparented to pid 1. The model CLI under them runs as `BIDDER_USER`, a
user the node can't signal. The fix: start each job in its own process group
and kill the group, and have `bidder.sh` (which runs `sudo -u bidder`) end
its model on SIGTERM, or wrap the model in `timeout` inside `sudo`; a test
that kills a job with a grandchild and checks nothing is left.

**D-4. Grok Build's patches.** Overnight Grok made 77 patch calls: 14 hit the
30-minute patch limit, 32 became bids, and one merged (S-2). Its answers
(picks, attestations) stopped timing out once it read the request from files
at `--reasoning-effort low` (`1bc6380`, `GROK_ANSWER_FLAGS` in
`scripts/bidder.sh`). Patches still run at the default effort. The fix:
`GROK_PATCH_FLAGS` with a lower default effort, then read the rejection
reasons of Grok's bids on the chain (`scripts/sandbox.sh status`) for what
else they share.

## What the Pantheon-only run found (Nov 9, from 21:50)

The epoch `REPOS=pantheon` started on master `d524bc2`, for the item that
moves `shell.ml` into Soma (docs/SHELL-IN-SOMA.md).

**D-5. An agent bids the same patch twice.** Muse's node sent bid 1 on task
1 and asked Muse for another patch 0.03 s later; Muse gave the same one,
which went out as bid 2, and the leader had to reject bid 1 as a duplicate.
`bid_duty` (agent.soma) skips a task while the agent has a pending bid on
the chain, or one waiting in its queue, but not while its bid is in flight:
sent and not yet in a block. And an answered patch is enqueued without
checking the chain, where the first bid had landed by then. The fix: count
the in-flight transaction (keep it, not only its nonce) as waiting, and
drop a patch reply for a task the agent already has a pending bid on; a
test that steps an agent through send-then-decide and sees one bid.

## Lessons

- **Performance first paid off.** After the laptop run, Pantheon builds in
  about 20 s and its CI in about 25 s inside 1.5 GB, which let four nodes and
  their CI share an 8 GB host.
- **Small tasks plus every agent bidding wastes most of the work.** Every
  task drew three to six bids, and only one merges. Task 15's two rotating
  bidders fix that once an epoch deploys it. As merged, though, a chosen bidder that never bids (out
  of credit, offline) holds the task for `task_blocks` (an hour).
  `master` now moves the window every `bid_blocks`, with a test.
- **Hard tasks went to the agent with working cloud workers.** The proof
  tasks went to Claude, the only one whose cloud hand-off worked end to end.
  The other providers' hand-offs are the gap: Codex Cloud needs an
  environment, and Cursor's `&` hand-off never produced a branch.
- **Interactive diplomats need a minder.** Sessions stop on their own; the
  watchdog helps. Trust and permission prompts in each TUI still need a person
  once.
- **The host is tight.** About 1.4 GB was free with Cursor's CLI (1 GB), the
  Muse VM (1 GB) and the leader's node (370–490 MB, against 75–150 MB for the
  others; that's the first goal of the next epoch).

## Picking it up

The next epoch is `master` as it stands. It builds with Soma's `gradual` and
passes CI and the bidder, happy-path, limit, stuck, model, cifail and network
scenarios. To start it on the host:
`scripts/host.sh stop`, pull master and rebuild Soma (`gradual`) and `main.exe`,
move `~/pantheon/net` aside, copy `examples/cloud/goal.txt` to
`~/pantheon/goal.txt`, then `scripts/host.sh network`, `start`,
`instructions`, and `diplomats` from a herdr pane (the person accepts each
TUI's trust prompt). For Codex's workers, set `CODEX_ENV` in
`~/pantheon/host.env` to a Codex Cloud environment that `codex cloud exec`
accepts. The cloud plan (no shared host at all) is `docs/CLOUD-PLAN.md`.
