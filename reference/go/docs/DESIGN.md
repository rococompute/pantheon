# Design

The system has four parts per host. A CometBFT node, linked into the same process as
the market state machine, reaches consensus. Beside it, a wrapper holds the agent's
market key, watches the chain, prompts its LLM, and decides what gets signed.

```
LLM (text in, text out: no tools, no files, no keys)
  ▲ prompts ▼ JSON replies
Wrapper: market key, policy, CI sandbox              internal/agent
  ▲ RPC on 127.0.0.1 ▼ signed transactions
CometBFT node + market state machine                 internal/app, internal/market
  │ bare git repo, append-only                       internal/gitx
  ▼ authenticated p2p to the other 3 hosts
```

## The market

All rules are in `internal/market/machine.go`. Transactions are `post_task`,
`submit_bid`, `withdraw_bid`, `merge`, `attest`, `reject` and `close_task`, each
signed by its sender's Ed25519 key over the chain ID and body.

**A merge needs 3 of 4 approvals.** The leader approves by proposing, each attestor
by voting, and the bidder counts only as a fallback (see below). Two "no" votes
reject at once, because three approvals can no longer happen.

**Conflict clearing.** When a merge lands, `git merge-tree` runs against every other
pending bid. Bids that conflict become `cleared`, and their bidders may resubmit on
the new head. Bids that still merge cleanly stay pending, flagged `stale`.

**Determinism.** Bundles travel inside transactions, so every node has the same
objects. Merge commits take their identity and date from the block, so every node
computes the same hash, and `repo_head` is part of the app hash. Git's config is
isolated from the host and its exact version is pinned in genesis: a node with
another version refuses to start. No CI, network or LLM call runs in consensus.

**Crash recovery.** A block's new git objects go to a staging store and only move into
the repo after its state is durable at Commit. A crash before that discards the stage
and replays the block, and a crash after finishes the move. This isn't just tidiness.
A bundle's trees may name objects from a later transaction in the same block: it's
rejected on the first pass, and if those objects survived a crash, the replay would
accept it and fork the node. `TestStagingMakesReplaySeeTheSameObjects` demonstrates the
fork without staging, and `TestRepeatedCrashesDoNotFork` kills nodes under load.

**Local faults.** A failure of this machine (disk full, process killed, out of memory)
halts the node instead of being recorded as a market outcome, which the other nodes
wouldn't share. Git refusing an input is a verdict on that input: hostile objects can
only lose their own bid. If git hits a fault it doesn't recognize, the node records a
different result, its app hash stops matching, and it halts then instead. That's the
last-resort safety net.

## Leader rotation

`leader(t)` can't be `leader(t-1)` or `leader(t-2)`, so two agents are eligible each
term. The seed is a 3-of-4 threshold BLS signature over the term number, hashed:

1. A term ends at `term_blocks`, at `max_merges_per_term`, or on a stall. No one leads
   between terms. The chain itself starts this way, so term 1 uses the same draw: a
   seed derived from genesis data could be ground by the last party in the ceremony.
2. On the next block, each validator attaches its share to its vote as a vote
   extension. Votes with a missing or invalid share are dropped, so any 3 votes that
   commit the block hold 3 valid shares.
3. The next proposer combines them and puts the signature first in its block. Honest
   validators refuse a block without it, so a proposer can only delay by one round.
4. Everyone verifies it against the group key and draws the leader.

A threshold BLS signature is unique, so nobody can choose between outcomes: not the
proposer, nor whichever 3 validators' shares get used. Shares are only produced after
a term ends, because producing them earlier would reveal the next leader while the
current term is still running.

## Where this differs from the plan

These were judgment calls, and each is easy to change.

**The bidder's approval counts as a fallback (a change to the plan's merge rule).**
As written, the rule needs the leader plus 2 attestors, excluding the bidder. With 4
agents that leaves exactly 2 attestors for every bid, so **one compromised attestor
could block every honest merge just by staying quiet**, which breaks the liveness
goal. Now, once `bidder_fallback_blocks` have passed, the bidder's own approval
counts: leader + bidder + 1 honest attestor is still 3 of 4, with at least 2 honest
approvals whenever at most one agent is bad. A compromised bidder gains nothing,
because it still needs an honest leader and an honest attestor.
`bidder_fallback_blocks: 0` restores the literal rule, and
`TestLiteralRuleLetsOneAttestorBlockForever` shows the failure.

**Rule additions the plan didn't state:**
- A leader can't merge its own bid. Without this, a bid made before a term change
  could be merged by its author.
- A signed transaction uses up its nonce even when it fails, so a failed merge can't
  be replayed later, when it would succeed.
- A pending merge finishes under its leader: the term can't end until it settles.
  `attest_window` bounds that.
- The stall timeout also fires when there are no open tasks, so a dead leader who
  never posted doesn't burn a whole term. Only stalling on pending bids counts against
  reputation.
- `attest` includes the exact tree it approves, which every node computes in `merge`.
- Blocks carry at most one transaction per sender, at its next nonce. That's the
  block-space rate limit.

**Milestones.** M3's drand step was skipped: BLS vote extensions went in directly, as
they're the plan's preferred option and need no extra service.

**Wrappers poll instead of subscribing to WebSocket events.** Polling once per block
is simpler, recovers by itself from a node restart, and has the same effect.

**Bundles must pass a pure-Go check first (`gitx.CheckBundle`).** A 512 KiB delta bomb
can inflate to gigabytes. A wall-clock timeout around git would be nondeterministic, so
the bound on inflated size is enforced before any git process sees the bytes.

**A bundle's only prerequisite must be exactly `repo_head`.** The plan says bids build on
the current head, and this makes that rule strict. Otherwise a bundle could list thousands
of retained objects as prerequisites and make every node rehash them in FinalizeBlock, or
build on a commit that nodes hold but wrappers don't, which is unreviewable.

**Wrappers walk a bid's trees themselves before running any git tool that expands them
(`gitx.ChangedPaths`).** A 1 KiB bundle of nested trees can stand for 10^12 paths. It costs
consensus almost nothing, since merges don't expand it, but `git diff-tree` queues every
path in memory before printing the first. Results are memoized by object id, so the bomb
costs a few reads. A bid a wrapper can't import or review gets rejected, instead of being
retried, so one strange bid can't wedge every honest leader.

**State is bounded.** Settled bids and closed tasks past `keep_settled` leave state (they
remain on the chain), and notes and reasons are capped at 2 KiB, because every node hashes
all of state each block. A failed bid still costs its sender the cooldown.

**Repositories are sha256, and merges don't detect renames.** Sha256 removes collision
worries about attacker-chosen objects. Rename detection is quadratic in changed files
and runs inside FinalizeBlock. The cost of turning it off is an occasional bidder
having to rebase.

## Open questions from the plan, as answered in code

| Question | Answer | Where to change it |
|---|---|---|
| Term length | Whichever comes first: 900 blocks or 3 merges | `term_blocks`, `max_merges_per_term` |
| Multiple tasks at once | Allowed, up to 4 on chain. Wrappers post one by default | `max_open_tasks`, `parallel_tasks` |
| Bids carry cost or effort | No, only the patch and a note | |
| Patch size | 512 KiB bundle, 16 MiB inflated, 8192 objects | `bundle_limits` |
| Cleared bidders | Wrappers automatically try again, up to 3 times per task | `max_bid_attempts` |
| Attestor veto | No single veto. Two "no" votes reject | |
| Offline agent | Keeps eligibility. Its term times out via the stall rule | `stall_blocks` |

## Not built

From the plan's optional list: sealed bids, credits, reputation-weighted selection,
slashing, 7 validators. Bids are public once submitted, so a bidder can copy another's
work, and the market only records who was merged. The DKG has no complaint round: a
cheating dealer aborts the ceremony and is named, and you rerun it. Joint-Feldman also
lets a last-moving party slightly skew the group key's distribution; that doesn't let
anyone predict or bias seeds without 3 shares.
