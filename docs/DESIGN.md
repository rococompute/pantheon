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
  height, round and kind, and remembers that across restarts in `signed.log`.
- **Blocks** hold at most one transaction per agent, at its next nonce, and honest
  validators refuse any other block.
- **Pacing.** A height's first round starts `block_ms` after the last decision, so
  transactions gather.

Restarts replay `blocks.log`, which holds decided blocks only, so a crash loses
nothing that had been agreed.

## The market

`market.soma`. The rules are those of the Go version (`reference/go/docs/DESIGN.md`),
with three simplifications that keep it small and easy to state theorems about:

- **A patch is a set of file writes made against a version**, not a git bundle. A
  pending bid conflicts with a merge when it writes a path that has changed since its
  version, and then it's cleared; otherwise it stays pending, marked stale. That is
  the same rule git applies, at file granularity, without git's nondeterminism to
  guard against.
- **The leader draw uses hash chains, not threshold BLS.** At genesis each agent
  commits to H^K(s). To seed a term, each reveals the link before its last one, which
  only it can compute, and the draw hashes the reveals in agent order. A value is
  fixed in advance, so all an agent controls is whether to reveal: withholding makes
  it ineligible. **Weaker than BLS**: an agent not eligible anyway can withhold, at no
  cost, to choose which of the two eligible agents leads. With one faulty agent it
  can't choose itself.
- **Signatures are RSA-2048**, because that's what the OCaml libraries in Soma's switch
  have. The Go version used Ed25519 and BLS.

The rest carries over: 3 of 4 approvals for a merge, the bidder counting after a
fallback delay so one silent attestor can't block merges, two no votes rejecting, a
leader never merging its own bid, and a term ending on its block budget, its merge
budget, or a stall.

## The agent

`agent.soma`. After each block, each agent does its duties in order: reveal for a draw,
lead, bid, then attest. It asks its model for drafts, patches, picks and verdicts. The
shell runs the model with every tool off, from an empty directory, and gives the reply
back as flattened JSON. Policy (denied paths, file limits) is checked before anything
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

## Not built, from the Go version

- **Multi-host setup without a dealer.** `init` makes every key in one place, which
  suits a single machine. For separate hosts, each needs its own keygen. Before
  starting, the genesis files' addresses must be edited identically on every host.
- **Bundle and tree-bomb defenses.** Patches aren't git objects, and a transaction
  is capped at 256 KiB.
- Prometheus metrics, deploy units, backups, and the headscale ACL. These are in
  `reference/go/deploy/` and apply unchanged.
