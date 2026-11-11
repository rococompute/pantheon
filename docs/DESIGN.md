# Design

## The split

Every decision is a pure function in Soma, and the OCaml shell only does what the
outputs say.

```
node.soma  step : obj -> list string -> obj * list (list string)
             ├── consensus.soma   Tendermint
             ├── market.soma      the market's rules, applied to each decided block
             └── agent.soma       this node's agent: what to do after each block
shell.ml   events in (messages, timers, model replies), outputs done (send, sign, write)
```

Events and outputs are lists of strings, because those cross Soma's OCaml boundary.
Numbers don't cross it yet. The shell contributes three functions the state machines
call: `sha256`, `hash_list` and `decode_tx`, which checks a transaction's signature.
They are deterministic and the same on every node, but the kernel never computes them,
so to a proof they are assumptions. `soma explore` lists them.

## Consensus

`consensus.soma` follows Algorithm 1 of Buchman, Kwon and Milosevic, *The latest gossip
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

`market.soma`. The rules are those of the first implementation, in Go on CometBFT
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
- **Merges are attested trees.** An attestor's node applies the edits to the head in
  a fresh clone, gets a tree, runs CI, and only then asks its model. The leader's
  merge names the tree its own check gave, and a yes counts only for that tree. So
  every merge has the leader and at least one attestor agreeing on it, and with at
  most one faulty agent, an honest node computed it. Every node then applies the
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
  next one (`draw_pool`, proved in `market.proof`): holding back never raises its own
  chance of leading, now or next term. It can still steer one draw at the cost of its
  own next chance, which honest-majority BLS would rule out.
- **Signatures are RSA-2048**, because that's what the OCaml libraries in Soma's switch
  have. The Go version used Ed25519 and BLS.

The rest carries over: by default n-f approvals for a merge (3 of 4), the bidder
counting after a fallback delay so one silent attestor can't block merges, f+1 no
votes rejecting, a leader never merging its own bid, and a term ending on its block
budget, its merge budget, or a stall. Two genesis settings change it. The
parameter `merge_approvals` sets the approvals a merge needs: 1 makes the leader
responsible alone, its own check and pick landing at once, with rotation and later
bids, not attestors, guarding against a bad leader; the dogfood network runs that
way. A part's `exclude` takes repositories out of an agent's scope: it isn't asked
to bid, lead or check there, and a merge there counts its quorum over the agents
whose scope has the repository (`scope`, `merge_n`; `market.proof` restates the
merge theorem with `merge_quorum`).

## The agent

`agent.soma`. After each block, each agent does its duties in order: reveal for a draw,
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
name and stored as `Any` (`util.soma`). Reading a field casts it, and a wrong field is a
run-time error rather than a static one. That keeps the code short: one line per field,
no record-update boilerplate. Messages, tasks, bids and proposals are typed records.

Tightening `obj` into typed records with invariants is where proofs start: see
[PROOFS.md](PROOFS.md).

## Not built yet

- **Membership changes.** Replacing an agent's keys, or adding a fifth, means a new
  genesis.
- **Prometheus metrics and deploy units.** The Go version's systemd units
  (`reference/go/deploy/` up to commit `4a6eab3`) apply with small changes.
- **Binary files.** Edits are text. A binary change is reported as skipped.
