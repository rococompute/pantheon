# Proof inventory and remaining work

`soma build main.soma` checks the proof files. This inventory includes every
Theorem, Lemma, Corollary and Example in `consensus.proof` and `market.proof`,
with its exact source name. These are statements about the pure definitions,
not proofs of the OCaml shell, extraction to machine integers, cryptography,
OS isolation, or deployed end-to-end safety. Shell hashes, decoding, signatures
and I/O are trusted. Gradual casts and `Any` remain part of the trust boundary;
a successful build alone does not rule out assumptions (`Admitted`, axioms,
`unk` or `err`). Inspect `soma explore main.soma` and assumption reports too.
The default host/sandbox CI policy rejects added assumptions; arbitrary CI
commands need not do so. Trusted toolchains and build-cache provenance matter.

## Checked statements

### consensus.proof

| Name | What it proves; limits |
|---|---|
| `num_opt_reads_digits` | The example 120 parses; no general parser correctness result. |
| `num_opt_refuses_19_digits` | The shown 19-digit input is refused; no resource bound proof. |
| `num_opt_refuses_non_digits` | The three shown malformed inputs are refused; no general parser theorem. |
| `quorums_intersect_in_an_honest_node` | Proves the roster-size inequality n + weak <= 2 * quorum for n >= 1; actual set intersection, membership and honest behaviour are external premises. |
| `four_validators` | For roster length four, quorum = 3 and weak = 2; does not validate the roster. |
| `lockr_changes_only_in_r_lock` | A rule preserving height leaves lockr unchanged or sets it to round + 1; no restart guarantee. |
| `mem_In` | Boolean string membership equals list membership; no authentication claim. |
| `nodup_s_In` | Deduplication preserves membership; no validator membership check. |
| `nodup_s_NoDup` | Deduplicated names have no repeats; no authentication claim. |
| `senders_witness` | Each counted name has a matching filtered message in the log; does not authenticate it. |
| `andb_split` | A true conjunction has two true operands; only a Boolean helper. |
| `find_some_in` | A successful find returns a list member satisfying its predicate; no protocol invariant. |
| `r_decide_needs_quorum` | Successful local decision has a valid proposal and quorum distinct matching precommit sender names in its log; membership and signatures rely on ingestion, not this theorem. |
| `r_decide_four_validators` | Specializes that local witness to at least three names for four nodes; no global agreement proof. |
| `r_catch_up_needs_weak` | Catch-up has weak distinct matching Done sender names at this height and round zero; no independent proof those senders decided honestly. |
| `r_catch_up_four_validators` | Specializes catch-up to at least two names for four nodes; no global agreement proof. |
| `r_lock_change_moves_forward` | Given lockr <= round + 1 and the new lockr = round + 1, the lock grows; does not establish the premise. |
| `locks_only_move_forward` | Under lockr <= round + 1, a height-preserving rule cannot decrease lockr; no reachability or persistence proof. |
| `r_lock_broadcast_precommit_step` | A precommit from r_lock moves step 1 to 2; only this local rule. |
| `r_nil_broadcast_precommit_step` | A precommit from r_nil moves step 1 to 2; only this local rule. |
| `r_fresh_no_precommit` | r_fresh emits no precommit broadcast; no trace property alone. |
| `r_reproposal_no_precommit` | r_reproposal emits no precommit broadcast; no trace property alone. |
| `r_prevote_timer_no_precommit` | r_prevote_timer emits no precommit broadcast; no timer delivery guarantee. |
| `r_precommit_timer_no_precommit` | r_precommit_timer emits no precommit broadcast; no timer delivery guarantee. |
| `start_round_no_precommit` | start_round emits no precommit broadcast; no restart guarantee. |
| `r_skip_no_precommit` | r_skip emits no precommit broadcast; no liveness guarantee. |
| `r_decide_advances_height` | Successful r_decide increments height; no agreement proof. |
| `r_catch_up_advances_height` | Successful catch-up increments height; no agreement proof. |
| `start_round_result_round` | start_round sets the requested round; does not show the requested round is larger. |
| `r_skip_advances_round` | Successful r_skip strictly advances round; no termination guarantee. |
| `rule_broadcast_precommit_step` | A height-preserving rule emitting a precommit moves step 1 to 2; no shell signing proof. |
| `rule_keeps_precommit_step` | A rule preserving height and round preserves step 2; excludes restart and other transitions. |
| `same_round_steps_keep_precommit` | The defined same-round rule closure preserves step 2; not arbitrary execution traces. |
| `one_precommit_per_round` | After one precommit, the specified same-round rule trace cannot emit another; not a global safety or crash-recovery theorem. |

### market.proof

| Name | What it proves; limits |
|---|---|
| `without_fallback_attestors_must_approve` | For any n, approvals >= n - f with fallback disabled requires n - f - 1 true vote entries; distinct authorized voters and tree checks are not proved here. |
| `fallback_attestors_must_approve` | For any n, approvals >= n - f requires n - f - 2 true vote entries even with fallback; does not prove who computed its tree. |
| `quorum_one`, `quorum_four`, `quorum_seven`, `quorum_eight` | The thresholds (n - f, f + 1, n - f) at n = 1, 4, 7, 8; n = 4 gives 3, 2, 3 as before n was a parameter. |
| `thresholds_one`, `thresholds_four`, `thresholds_seven`, `thresholds_eight` | approved_at, rejected_at and draw_ready at, just below and just above each threshold. |
| `q7_*` | settle and maybe_draw themselves at n = 7: 4 approvals pending, 5 merge; 2 no pending, 3 reject; 4 reveals wait, 5 draw after the window, wait inside it; 7 draw at once. |
| `faults_spec` | 3f <= n - 1: f = (n-1)/3 is below a third of n. |
| `quorum_plus_reject` | (n - f) + (f + 1) = n + 1 for every n, so n distinct voters can't reach both. |
| `approval_quorums_intersect_in_an_honest_agent` | n + f + 1 <= 2(n - f) for n >= 1: two approval quorums share f + 1 agents, one of them honest with at most f faulty; set membership is an external premise. |
| `approved_and_rejected_exclusive` | yes + no <= n rules out both approved_at and rejected_at. |
| `votes_split` | True and false vote entries add up to all of them. |
| `merge_never_both_approved_and_rejected` | With at most n - 2 vote entries, a proposal can't have n - f approvals (fallback or not) and f + 1 no votes; that the entries are distinct agents is the attest rule's, not proved here. |
| `draw_goes_on_with_f_silent` | With k <= f agents silent, n - k reveals make draw_ready true once the window passed. |
| `holding_back_bars_you_from_the_next_draw` | A held name is excluded from draw_pool if a non-held revealer exists; no unbiased randomness guarantee. |
| `draw_pool_not_nil` | The pool is nonempty if a non-held revealer exists; no guarantee anyone reveals. |
| `getf_setf_other` | Updating a different key preserves lookup; only a record helper. |
| `leader_setf_other` | Updating another field preserves leader; no leader authorization proof. |
| `leader_setf_leader` | Setting the leader field reads back that string; no election correctness proof. |
| `maybe_draw_bars_who_held_back` | With a non-held revealer, either no draw changes state or its leader differs from a held name; not unconditional exclusion when no draw occurs. |
| `bids_setf_other` | Updating another field preserves bids; only a record helper. |
| `bids_setf_bids` | Setting bids reads back that list; no bid validity proof. |
| `merged_setf_other` | Updating a non-bids field preserves any property of Merged bids; assumes the property initially. |
| `merged_set_bid` | Replacing a bid with a non-Merged bid preserves the property; assumes it initially. |
| `merged_count` | Updating counters preserves the property of Merged bids; assumes it initially. |
| `merged_clear_fold` | A fold preserves the property if every step does; no independent clearing correctness proof. |
| `settle_preserves_merged` | Settlement preserves the property if authorized finalize calls do; conditional on that finalize premise. |
| `merged_append_pending` | Appending a non-Merged bid preserves the property; assumes it initially. |
| `apply_preserves_merged` | Transaction application preserves the property given the finalize premise; no concrete tree property established. |
| `end_term_preserves_merged` | Ending a term preserves the property of Merged bids; assumes it initially. |
| `draw_preserves_merged` | Drawing preserves the property of Merged bids; no fairness claim. |
| `prune_preserves_merged` | Pruning preserves the property for remaining Merged bids; no retention guarantee. |
| `merged_block_fold` | A block fold preserves the property if each step does; conditional helper. |
| `apply_block_preserves_merged` | A whole block preserves the property given the authorized-finalize premise; does not discharge that premise for a concrete property. |
| `bid_eq_dec` | Bid equality is decidable; no bid validity claim. |
| `merged_only_through_finalize_with_quorum_approvals` | A Merged bid record absent from the input comes from finalize with pending proposal and merge_quorum approvals (n - f of the bid's roster by default); not a tree-agreement proof or an assertion of fresh finalization for old records. |
| `bidders_for_at_most_two` | Selection returns at most two bidders even for malformed rosters; no fairness guarantee. |
| `bidders_for_excludes_leader` | The selected bidders exclude the current leader; no claim about earlier leaders' bids. |
| `self_merge_makes_no_proposal` | A merge naming the sender's bid fails with a reason and unchanged state; no liveness guarantee. |
| `merge_needs_leader_and_others_bid` | A successful merge command is from the leader and names someone else's existing bid; does not prove finalization. |
| `apply_reveal` | Expands the reveal branch and its guards; no cryptographic assumption proved. |
| `getf_setf_same` | Lookup of an updated key returns its value; only a record helper. |
| `reveals_after_reveal` | Updating reveals then tips retains the reveals list; no reveal validity claim. |
| `accepted_reveal_is_the_next_link` | An accepted reveal hashes in one step to the current tip; no hash injectivity proof. |
| `reveal_one_step_regression` | Under the stated draw, tip and hash-inequality premises, the next link succeeds and an older link fails; not a universal hash property. |
| `second_reveal_for_a_draw_is_refused` | Immediately after acceptance, another reveal from that agent is refused; does not cover a later draw. |
| `accepted_reveals_for_a_draw_are_equal` | Two alternatives accepted from the same state hash to the same tip; equality requires the explicit unique-preimage premise, not proved SHA-256 injectivity. |

## Remaining work

- Type the consensus, market and agent states and remove gradual escape hatches.
- Prove global consensus agreement across authenticated nodes and restart traces.
  The local lock and precommit results above do not establish this. A
  restarted node keeps its lock (`consensus.state`; security review P-4, done,
  tested by `test/restart-lock.sh` and `test/e2e.sh`), but that's a test, not
  a proof.
- Prove tree agreement through vote admission, settlement and shell application.
  Approval arithmetic and the finalize-origin result are only parts of this.
- Prove exact conflict clearing, rotation fairness and policy before signing.
- Use dependent types to represent validated paths and edits.

Keep proofs beside their programs, reduce assumptions reported by `soma explore`,
and never weaken tests to make a proof pass or weaken proofs to make tests pass.
