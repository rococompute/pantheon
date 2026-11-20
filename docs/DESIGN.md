# Design

## The split

Every decision is a pure function in Soma, and Soma's host library (`Soma.Host`)
only does what the outputs say. Pantheon has no OCaml of its own.

```
runtime/node.soma  step : obj -> list string -> obj * list (list string)
             ├── core/consensus.soma   Tendermint
             ├── core/market.soma      the market's rules, applied to each decided block
             └── core/agent.soma       this node's agent: what to do after each block
runtime/node_kernel.soma   the node's kernel: tables, peer links, signatures, files, the select
runtime/node_host.soma   the kernel's host work: a merge's git, the model's limit, jobs, checks and CI
app/cli.soma   the commands, the node's setup, and the edits machinery
runtime/node_net.soma   the binary's network: links, buffers, the select, the service's socket, the jobs' processes
runtime/node_git.soma   git, a clone and a program run to its end, over the host's processes
runtime/node_path.soma   a path in a checkout looked at part by part, no symlink on the way
runtime/node_file.soma   a file written whole (temporary, mode kept, renamed, synced), directories made, trees removed in the background
runtime/node_service.soma   the node's service for an image: only the node's own host work, its loop
Soma.Host   Soma's: the host's primitives, descriptors by name, files, paths, processes
```

The kernel is the same program in the binary and in the unikernel: runtime/node_net.soma over
Soma.Host's sockets carries out its primitives for the binary, Sandbox for the unikernel (docs/SHELL-IN-SOMA.md, "One
kernel, two runners").

Events and outputs are lists of strings, the answers of Soma.Host's primitives.
`sha256`, `hash_list` and `decode_tx`, which checks a transaction's signature, are
Soma's (Soma.Crypto): the kernel computes them. The primitives are what the kernel
never computes, so to a proof they are assumptions. `soma explore` lists them.

## Consensus

`core/consensus.soma` follows Algorithm 1 of Buchman, Kwon and Milosevic, *The latest gossip
on BFT consensus* (2018), one definition per rule, named by its lines. It needs 3 of 4
for every quorum, and tolerates one faulty validator. What the paper leaves to
implementations:

- **Delivery.** Every node resends its messages for the current height every 2 s,
  so a dropped link only delays a message.
- **Catching up.** A message for an old height makes the receiver send the blocks the
  sender missed, as `Done` messages. Two matching ones are enough, since at most one
  node is faulty.
- **Never signing twice.** The shell refuses to sign a second, different vote for one
  height, round and kind, and remembers that across restarts in `signed.log`, which
  keeps each whole vote. Asked for a different one, it sends the vote it signed
  before. A restarted node that stayed silent instead would hide that it's behind,
  and catching up starts when the others hear from it.
- **Blocks** hold at most one transaction per agent, at its next nonce, and honest
  validators refuse any other block.
- **Pacing.** A height's first round starts `block_ms` after the last decision, so
  transactions gather.

Restarts replay `blocks.log`, which holds decided blocks only, so a crash loses
nothing that had been agreed.

## The market

`core/market.soma`. The rules are those of the first implementation, in Go on CometBFT
(`reference/go/docs/DESIGN.md` in the git history, up to commit `4a6eab3`), with
changes that keep it small and easy to state theorems about:

- **The market holds no file contents.** It governs git repositories, and keeps only
  each one's head tree and, per path, the version that last changed it. Genesis
  names each repository's URL, commit and tree, and every node keeps a checkout.
- **A patch is a list of edits against a version**, not a git bundle. An edit
  replaces the one place an exact piece of text appears in a file, writes a whole
  file, or deletes one. Edits are small, so a repository the size of Soma costs
  nothing more than a small one, and models are good at them. A bid may name any
  version so far, and goes stale only on a real conflict, at the granularity of
  lines rather than files: its replacements still apply when each one's text is
  still there exactly once (the leader's merge check applies them to the head, and
  clears a bid whose edits don't, which isn't a rejection), and a whole-file write
  or delete conflicts with any change to that file since. A stale bid costs its
  bidder nothing: the version moving gives it fresh tries for an updated one.
- **Several tasks at once.** Up to `max_open_tasks` (a genesis parameter, 1 by
  default) are open together, each with its own bids and record of rejections.
  The leader drafts another while there's room, when it judges one can run beside
  the open ones (other files, not needing their result), and picks each task's
  bids on their own.
- **A market can finish, or run on.** By default a market runs until it's
  stopped: its plans are a standing source of work, which can be refilled at
  any time (a `.plan` kept in sync with an issue tracker, say). With
  `--param finish=1` at `pantheon init`, it works toward a deliverable and
  stops when that's done: a leader that finds no task to post, with none open,
  sends `finish`, and its term ends at once. Once every agent on the roster has
  said so, with no task posted since the first of them (a post clears the
  votes), the market is `finished`: no more terms are drawn, `pantheon status`
  says so, and each node stops 10 seconds later, with status 0, so its peers
  still get its last votes. `test/finish.sh` checks both kinds.
- **Bids have titles, for people.** A bidder titles its bid (up to 60
  characters, `tbid`), and a leader that merges or rejects one gives it a
  title of its own: what it does for the goal in plain words, or why not
  (`merge BID TREE HEAD TITLE`, `reject BID WHY TITLE`). The market keeps them
  apart from the bids (`titles`, `verdicts`), no rule reads them, and one that
  isn't plain text of 1 to 60 characters is dropped while its transaction
  stands. `pantheon status` shows the last 20 bids' titles and notes, which
  cmux's plan view lists.
- **Merges are attested trees.** An attestor's node applies the edits to the head in
  a fresh clone, gets a tree, runs CI, and only then asks its model. The leader's
  merge names the tree its own check gave, and a yes counts only for that tree. So
  under the default four-node policy every merge has the leader and at least
  one attestor agreeing on it, and with at most one faulty agent, an honest node computed it. Every node then applies the
  edits to its checkout and commits with fixed metadata, so each merge is the same
  commit everywhere. A checkout that doesn't reach the tree has diverged, and says
  so.
- **The leader draw uses hash chains, not threshold BLS.** At genesis each agent
  commits to H^K(s). To seed a term, each reveals the link before its last one, which
  only it can compute, and the draw hashes the reveals in agent order. A value is
  fixed in advance, so all an agent controls is whether to reveal: withholding makes
  it ineligible. **Weaker than BLS**: whoever reveals last sees the other links and can
  hold back to swap the four-link seed for a three-link one. That lets a recent leader,
  barred anyway, choose which of the two eligible agents leads, and be repaid next
  term by the one it chose. So an agent that holds back in a draw is barred from the
  next one (`draw_pool`, proved in `core/market.exp`): holding back never raises its own
  chance of leading, now or next term. It can still steer one draw at the cost of its
  own next chance, which honest-majority BLS would rule out.
- **Signatures are RSA-2048**, because that's what the OCaml libraries in Soma's switch
  have. The Go version used Ed25519 and BLS.

Two/three-node markets use separate merge review rules. With two, the leader's
checked proposal suffices. With three, the leader needs one other node to attest
to the same tree; the contributor and leader cannot attest. Bidder fallback is
disabled for both sizes, including for old proposals, and `merge_approvals`
does not override this policy. Block consensus and leader draws still require
every node: these markets tolerate zero faulty or unavailable validators.
The policy uses the whole active roster, so a two-member repository scope in
a larger market does not silently become a two-node market. A normal leader
still cannot merge its own contribution, and queued bids survive term changes.

For four or more the rest carries over: by default n-f approvals for a merge (3 of 4), the bidder
counting after a fallback delay so one silent attestor can't block merges, f+1 no
votes rejecting, a leader never merging its own bid, and a term ending on its block
budget, its merge budget, or a stall. Two genesis settings change it. The
parameter `merge_approvals` sets the approvals a merge needs: 1 makes the leader
responsible alone, its own check and pick landing at once, with rotation and later
bids, not attestors, guarding against a bad leader; the dogfood network runs that
way. With no attestor recomputing the tree, a merge or a mark names the head its
tree was checked on (`merge BID TREE HEAD`), and the market refuses it once the
repository has moved past that head: a check that answers after another merge
landed is the old head's, and its tree is one no node reaches. The leader's agent
checks such a bid again on the head instead (`moved_since`). A part's `exclude` takes repositories out of an agent's scope: it isn't asked
to bid, lead or check there, and a merge there counts its quorum over the agents
whose scope has the repository (`scope`, `merge_n`; `core/market.exp` restates the
merge theorem with `merge_quorum`).

## The agent

`core/agent.soma`. After each block, each agent does its duties in order: reveal for a draw,
lead, bid, then attest. It asks its model for drafts, patches, picks and verdicts. A
prompt names what it needs from the checkouts (`{{REPOS}}` for file lists, `{{REPO}}`
for a task's context files), and the shell fills it in. Built-in backends run with
every tool off, from an empty directory. A `cmd:` backend asked for a patch also gets
a fresh checkout of the task's repository, so a model with tools can edit, build and
test there; `pantheon edits` turns what it changed into the reply. Replies come back
as flattened JSON. Policy (denied paths, file limits) is checked before anything
is signed, merged or approved, and a model can't talk the wrapper past it. One
transaction is in flight at a time.

The scripted backend lives in Soma, so a test network needs no model and no shell
round trip.

## Gradual types, on purpose

The state machines keep their state in `obj`, a record whose fields are looked up by
name and stored as `Any` (`core/util.soma`). Reading a field casts it, and a wrong field is a
run-time error rather than a static one. That keeps the code short: one line per field,
no record-update boilerplate. Messages, tasks, bids and proposals are typed records.

Tightening `obj` into typed records with invariants is where proofs start: see
[PROOFS.md](PROOFS.md).

## Not built yet

- **Membership changes.** Replacing an agent's keys, or adding an agent genesis
  doesn't name, means a new genesis. Removing an absent agent and taking it back
  is planned: below.

### Membership by heartbeat (`.plan` M-3)

The roster is fixed at genesis today, so the quorum is always n - f of the
genesis agents. Eight agents on two machines need 6 votes, and either
machine's four alone can't decide anything. The roster should instead follow
which agents are there, decided on the chain like any other transaction,
with no script on the host: a machine can lose power before any script runs.

- **The heartbeat is the chain itself.** Each block records the agents whose
  precommits decided the block before it, as Tendermint's last commit does.
  Every node then reads the same absences from the same blocks; no node's own
  view of who is up decides anything.
- **Leaving.** An agent missing from those records for `absent_blocks` (a
  genesis parameter) is removed by a roster transaction. The leader proposes
  it and validators check it against the records. It takes effect a fixed
  number of blocks after the block that holds it, so every node switches at
  the same height.
- **Coming back.** A genesis agent that was removed catches up first (f + 1
  matching `Done` messages, with f counted on the roster at that height),
  then sends a join transaction signed with its key. The quorum commits it,
  and it takes effect the same way.
- **The thresholds follow the roster.** n, f = (n - 1)/3, the commit quorum,
  the f + 1 rules (catching up, skipping to a later round), merge approvals,
  rejection, and the draw's reveals are all counted on the roster at that
  height (`faults`, `quorum` and `draw_ready` already take n). A
  `min_roster` genesis parameter bounds how far it shrinks.
- **The market follows it too.** Removed agents leave rotation, bidder choice
  and the draw. A removed leader's term ends. Bids by a removed agent stay as
  they are and can still merge. A repository with no remaining agent in its
  scope waits, as tasks outside a leader's scope already do.
- **Proofs.** core/consensus.exp: two quorums at one height intersect in an
  honest validator when both are counted on the roster that height's blocks
  name. That roster is fixed before the height starts, which the delay
  ensures. core/market.exp: the existing theorems with n read at each height. A
  test in a new `test/*.sh` runs eight nodes, stops two, and checks that the
  six remove them, keep merging with 5 votes, and take them back once they
  return.

**What this can't do.** Every change still needs the current quorum. So the
roster can shrink step by step, up to f agents between changes, but a
machine holding more than f of the agents halts the market if it goes all at
once. From the other side, that looks the same as the network between them
being cut. If each half removed the other, there would be two chains merging
different work, which is what BFT exists to prevent. To survive losing a
whole machine, each machine must hold at most f agents (four machines with
two each, for eight), or one machine must be allowed to halt the market.
- **Prometheus metrics and deploy units.** The Go version's systemd units
  (`reference/go/deploy/` up to commit `4a6eab3`) apply with small changes.
- **Binary files.** Edits are text. A binary change is reported as skipped.

M-3 transaction admission is available as the typed, pure
`commit_roster_fields` boundary. It reuses the delayed schedule above and accepts
exactly `roster leave NAME` from the current term leader, or `roster join NAME`
from that genesis member itself. Leaves require the configured consecutive
agreed absences; the projected roster includes queued changes and must retain
at least `max 1 min_roster` members. Duplicate pending operations and an
activation earlier than an already scheduled change are refused. A join waits
until removal has taken effect and cannot add a name outside genesis. Tests
cover admission, 7-to-6 and 4-to-3 thresholds, and a delayed rejoin.

The caller must authenticate the sender, supply a previously validated schedule
and **agreed** previous-block certificates, then commit the admitted transaction
through consensus. This helper is not yet dispatched by `market.apply`: live
certificate transport and roster switching remain pending. No local connection
view or arbitrary transaction may populate the agreed heartbeat history.

M-3 portable certificate validation is provided by
`consensus.validate_commit_evidence`. Each witness carries a signer, signature
and the exact signed peer-message fields. The verifier callback checks a
peer line's signature (nodeio's `nio_line_verify` with the signer's genesis
key and the chain ID, Soma's RSA). Votes
must be precommits for the actual previous block's hash, height and one round,
from distinct members of **that previous height's roster**. A certificate needs
that roster's quorum, cannot exceed its size, and yields canonical roster-order
signer names. Exact signed bytes are retained, including numeric spelling.

`append_commit_evidence` starts the history at height 1, requires each next
height, and preserves the validated prefix. Callers must supply an already
validated, agreed prefix and the actual previous block. Missing or replayed
records cannot advance this boundary. These helpers do not prove that an
omitted member never voted. Live code must retain/transport signed witnesses,
commit the complete certificate in the next block, validate it during replay,
and connect membership admission and roster activation. A local certificate
must not be treated as agreed history. No live removal path is enabled here.

The certified admission bridge is `market.commit_certified_roster_fields`.
`consensus.verify_height_certificate` constructs the consensus state from
`roster_of h`, so a certificate is always checked against its own height's
roster. `certified_commit_window` reads exactly the configured number of
consecutive certificates, in descending height order, from an **agreed chain
record lookup**, and checks each against the actual block lookup and signature
verifier. Missing records/blocks, stale heights or invalid votes refuse the
whole window. At the start of block h, it uses certificates through h-2,
already recorded in blocks through h-1; the current candidate cannot replace
older heartbeat choices with a different valid subset. Rejoins need no absence
history, but retain the signed-sender/genesis/pending-change admission rules.

The two lookups must be adapters over committed blocks; a local certificate
cache or peer-supplied history does not meet their contract. Wire encoding,
these chain adapters, live dispatch and roster activation remain unimplemented.
The market now follows the roster at its height: `roster_now` is
`roster_at` over genesis's agents and the market's `roster_changes`, which
stay empty until a roster transaction is dispatched, so a stable roster
counts exactly as before. Scope, bidder choice, merge quorums, rejection and
the draw count it. `settle` counts only the votes of agents on that roster
(`counted_votes`), including the leader's implicit approval and the bidder's
fallback, so a vote cast before its voter was removed counts for nothing and
counts again once it rejoins. The draw counts and seeds with reveals of that
roster only, and holds back only its members. A removed leader isn't
`is_leader`, and its term ends in the block its removal takes effect, even
with a merge pending, which then settles on the attestors' votes or lapses.
`test/roster-activation.sh` checks these through `settle`, `maybe_draw` and
`maybe_end_term`. Consensus switches its validators the same way: after
applying block h, `on_decided` enters `roster_at` for h + 1
(`consensus.enter_roster`), so n, f, the commit quorum and the f + 1 rules
(catching up, skipping rounds) count that height's roster, and messages
already logged from agents off it are dropped. The same roster leaves the
state untouched. A validator off the roster takes no block as valid
(`member_valid` in `consensus.settle`): it neither locks nor decides on its
own vote, and moves on only by f + 1 `Done` messages. A peer one height
behind also gets a node's own signed messages at that height again
(`catchup_plan`): a node that decided alone, its precommit lost or
never sent (it stopped after saving it), is then not the only one who
can finish the others' quorum. A node started again stays in its round
with that round's timers (`resume_timers`), and sends what it signed at its
height again and keeps resending it (`resume_signed_prog`); a step's votes
are in signed.log before its snapshot is saved (`sign_effects`).
`test/roster-consensus.sh` checks this. Still to do: committing precommit
certificates in blocks and dispatching roster transactions.

The bridge is pure and enables no live removals. The new per-height quorum,
window-length and certified commit-height theorems accompany 26 fixed bridge
checks and the 32 signed-witness checks. This extends the earlier validation
prerequisite without adding another signature primitive.

M-3's portable certificate field codec is `encode_commit_certificate` /
`decode_commit_certificate` in core/consensus.soma. The `commit-v1` header carries
height and round, followed by seven string fields per witness (signer,
signature, and the five exact signed message fields). It preserves signed
numeric spelling and signatures without splitting strings on whitespace.
Malformed headers, numbers and incomplete witnesses fail decoding; encoding
refuses witnesses with any other field count. The proved witness round trip
preserves the whole witness, including signed bytes. This is structural
transport only: decoding does not authenticate a certificate or establish
agreement, and consumers must still call `verify_height_certificate`.
`test/commit-wire.sh` checks exact deterministic results. Integrating these
fields with block framing, signature retention, committed-chain lookups and
roster dispatch remains pending; this codec enables no live removal.

M-3's opt-in block envelope is `frame_commit_block` /
`unframe_commit_block`: `heartbeat-v1`, a certificate field count, the
`commit-v1` fields, then transaction strings. The count separates evidence
from transactions without altering signed strings. `chain_commit_at block_at h`
reads only the certificate carried by committed block h+1 and refuses a
certificate naming another height, missing carriers and height zero. Pass
this adapter to `certified_commit_window` or
`commit_certified_roster_fields` with a committed-block lookup; the existing
verifier still authenticates evidence against the actual block and roster
at h. `test/commit-carrier.sh` checks framing, malformed carriers, missing
history and verification through that adapter, including a signer removed
at the carrier height but present at the certified height.

This is a framing and lookup prerequisite, not a live format migration:
block construction/validation, signature retention, persistence/replay and
roster dispatch still need to adopt it together. Existing live blocks are
unchanged and no removal path is enabled by the envelope alone.

M-3's `prior_chain_commit_at` reuses the `heartbeat-v1` block envelope. At
candidate height h it consults only carriers strictly before h, with each
certificate's field count bounded by three header fields plus seven times
the roster size at the certificate's own height. `certified_chain_window`
authenticates those certificates against the full committed blocks they
signed, using the existing verifier and historical rosters.
`commit_chain_roster_fields` supplies that lookup to existing certified
admission: the newest eligible certificate is h-2, joins require no history,
and committing-height rosters and quorums remain unchanged. The caller must
supply the unique committed block lookup, never a local peer cache. The
adapter does not yet enable live framing, witness retention, automatic
removal proposals or transaction dispatch. `test/chain-roster.sh` checks
actual nested carriers, bounds, cutoff heights, authentication failures,
delayed removal and rejoin; real-node adoption remains separate work.
