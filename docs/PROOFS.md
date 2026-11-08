# What to prove next

This is the list for agents rewriting Pantheon to use more dependent types and proofs.
Each item is small enough for one pull request. `soma build` checks every `.proof`
file, and `test/e2e.sh` must still pass.

## Proved so far

| Theorem | File | Says |
|---|---|---|
| `quorums_intersect_in_an_honest_node` | consensus.proof | Two quorums share f + 1 validators |
| `four_validators` | consensus.proof | With 4 validators, a quorum is 3 and f + 1 is 2 |
| `without_fallback_two_attestors_must_approve` | market.proof | A merge needs 2 attestor yes votes |
| `fallback_still_needs_an_attestor` | market.proof | Leader plus bidder is not enough |
| `holding_back_bars_you_from_the_next_draw` | market.proof | An agent that held back its link can't win the next draw |
| `maybe_draw_bars_who_held_back` | market.proof | The same at `maybe_draw`: an agent in `held_back` isn't the leader it draws |

## Next, roughly in order

1. **Type the consensus state.** Replace consensus's `obj` with a `Record`, and its
   accessors with fields. Every `consensus.*` escape hatch in `soma explore main.soma`
   should disappear. Do the same for the market's, then the agent's.
2. **One precommit per round.** An honest node never precommits two different non-nil
   values in one round. Follows from `r_lock`'s one-time flag and the step it sets.
3. **Locks only move forward.** `lockr` never decreases within a height, and changes
   only in `r_lock`.
4. **Decisions need a quorum.** `r_decide` and `r_catch_up` only fire with 3, or 2,
   distinct senders behind the value.
5. **Model-check consensus.** An `Explore` model (see Soma's GRADUAL.md) of four nodes,
   one of them Byzantine, small heights and rounds. Invariant: no two honest nodes
   decide different values at one height.
6. **The merge rule.** In `apply_block`, a bid becomes `Merged` only through
   `finalize`, which `settle` calls only when `approvals` is at least 3. With
   `fallback_still_needs_an_attestor`, that gives the tree rule: every vote that
   counts as yes names the leader's tree, so a recorded head tree was computed by
   the leader and at least one attestor.
7. **Conflict clearing is exact.** After `finalize`, each still-pending bid edits no
   path changed since its version, and each one cleared does.
8. **A leader never merges its own bid.** No `merge` transaction from the bidder makes a
   proposal.
9. **Rotation.** When `eligible m` has someone outside the last two leaders, the drawn
   leader is one of them. (Its fallbacks only apply when every revealer led recently.)
   Then lift `holding_back_bars_you_from_the_next_draw` from `draw_pool` to
   `maybe_draw`: the agent `maybe_draw` records in `held_back` is never the next leader.
10. **Policy before signing.** Every `bid`, `merge` or yes `attest` the agent enqueues
    passes `violation`.
11. **Dependent types where they pay.** For example, a bid whose edits are
    `{w : list edit | forallb (fun e => safe_path (epath e)) w = true}`, so an unsafe
    path can't even be represented past `apply`.

## Rules

- A theorem goes in the `.proof` file next to its program, in proof sentences where
  they read well (see Soma's GRADUAL.md, Proof sentences).
- `soma explore main.soma` should only ever list fewer escape hatches and assumptions.
- Never weaken a test to make a proof easier, and never the other way around.
