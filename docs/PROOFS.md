# Proof inventory and remaining work

`soma build main.soma` checks the proof files. This inventory includes every
Theorem, Lemma, Corollary and Example in `core/consensus.exp` and `core/market.exp`
(and the main statements of `core/agent.exp`, `runtime/node.exp`'s vote and snapshot sections, `runtime/node_service.exp`, `runtime/node_path.exp`, `runtime/node_file.exp`, `runtime/node_git.exp` and `app/cli.exp`, below),
with its exact source name. These are statements about the pure definitions,
not proofs of Soma.Host's primitives (the host's I/O), extraction to machine integers, cryptography,
OS isolation, or deployed end-to-end safety. Soma.Host's I/O is trusted,
and Soma.Crypto's hashes and signatures are computed but not proved correct. Gradual casts and `Any` remain part of the trust boundary;
a successful build alone does not rule out assumptions (`Admitted`, axioms,
`unk` or `err`). Inspect `soma explore main.soma` and assumption reports too.
The default host/sandbox CI policy rejects added assumptions; arbitrary CI
commands need not do so. Trusted toolchains and build-cache provenance matter.

## Checked statements

### core/consensus.exp

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
| `filter_negb_length`, `forallb_false_witness` | List helpers: a filter and its complement add up to the list; a false `forallb` has a witness. |
| `common_members` | Two duplicate-free lists inside a roster share at least as many members as their lengths exceed the roster's. |
| `member_outside` | A duplicate-free list longer than the faulty list has a member outside it. |
| `quorums_share_an_honest_member` | Two quorums of one roster's members (duplicate-free) share a validator outside any list of at most f faulty ones: the set intersection `quorums_intersect_in_an_honest_node`'s arithmetic stands for. |
| `precommitter_has_precommit`, `precommitters_on_roster` | A certificate name has a precommit in the log at this height, round and value; when the log holds only the roster's messages, every name is on the roster. |
| `same_round_decisions_agree` | Two nodes on one roster at one height, logging only the roster's messages, with at most f faulty validators: when both decide and their decisions' proposals are of one round, they decide one `vid`, or a validator outside the faulty ones has a precommit for each of the two values in that round, one in each log, which `one_precommit_per_round` rules out for an honest node. Premises: that a logged precommit is its sender's (the node checks signatures before the log; not modelled) and a collision-free hash for one value per `vid`. Decisions in different rounds (locks carried across rounds) are not covered. |

### core/market.exp

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
| `moved_head_merge_makes_no_proposal` | A merge naming a head its bid's repository has moved past (`moved_since`) fails with a reason and unchanged state; does not prove the named tree is right. |
| `merge_needs_leader_and_others_bid` | A successful merge command is from the leader and names someone else's existing bid; does not prove finalization. |
| `apply_reveal` | Expands the reveal branch and its guards; no cryptographic assumption proved. |
| `getf_setf_same` | Lookup of an updated key returns its value; only a record helper. |
| `reveals_after_reveal` | Updating reveals then tips retains the reveals list; no reveal validity claim. |
| `accepted_reveal_is_the_next_link` | An accepted reveal hashes in one step to the current tip; no hash injectivity proof. |
| `reveal_one_step_regression` | Under the stated draw, tip and hash-inequality premises, the next link succeeds and an older link fails; not a universal hash property. |
| `second_reveal_for_a_draw_is_refused` | Immediately after acceptance, another reveal from that agent is refused; does not cover a later draw. |
| `accepted_reveals_for_a_draw_are_equal` | Two alternatives accepted from the same state hash to the same tip; equality requires the explicit unique-preimage premise, not proved SHA-256 injectivity. |

### runtime/node.exp: never two votes at one slot

An honest node signs at most one vote for a kind, height and round (a slot,
`broadcast_key`): the guard that keeps one node from forging two validators'
worth of votes (docs/DESIGN.md, "Never signing twice"). Statements about the
pure plan and program; that the signed-vote table returns what was signed
is shown within a height's list (the AVL map's find-after-add is not proved).

| Name | Checked statement |
|---|---|
| `honest_mode_is_all`, `honest_deliver` | An honest node's broadcast is one message to every peer, recorded as itself. |
| `honest_deliver_sends_its_fields` | What an honest node delivers sends only its own fields and records no vote. |
| `first_vote_at_a_slot_is_recorded` | A slot's first vote is recorded (`RememberVote`) before it is sent. |
| `honest_node_never_sends_a_second_vote` | Once a slot has vote `v`, every action records no vote, and sends only the asked-for message when it is `v`, else the stored message, else nothing. |
| `sign_prog_signs_only_an_empty_slot` | Whatever the host answers, `sign_prog` signs at a slot only when its look-up found nothing there. |
| `sign_prog_trace` | `sign_prog` is exactly the slot's look-up, then the signing when it is empty. |
| `signed_slot_list_found`, `signed_slot_list_others`, `lookup_filter_other` | Within a height, signing a slot makes it found with that vote and leaves the other slots' votes as they were. |

### runtime/node.exp: the snapshot reads back

`snapshot_text_reads_back`: `snapshot_of (snapshot_text c) = Some c`. A node
that saves its consensus state (`consensus.state`) and starts again from the
file has the state it saved: lock, valid value, round, step and log. The
premise, `snapshot_fits`, is the reader's own limit: each number read back
has at most 18 digits (as `num_opt` accepts), the state's numbers and each
saved string's length; `new_consensus_fits` checks that a new chain's state
meets it. That the bytes on disk are the bytes written is Soma.Host's.

| Name | Checked statement |
|---|---|
| `sapp_nil_r`, `sapp_assoc`, `slen_sapp`, `substr_at`, `substr_prefix`, `substring_zero`, `concat_empty_cons` | String helpers: appending, its length, and a substring at an append's seam. |
| `counted_cons`, `counted_length` | `counted` writes each string as its length, ":" and itself, and is at least as long as its count of strings. |
| `digits_uint`, `uint_digits`, `show_digits` | `digits` reads Soma's decimal text the way `Nat.of_uint` does; a shown number is all decimal digits. |
| `num_opt_nonempty`, `num_opt_uint`, `num_opt_show` | `num_opt (show n) = Some n` when `show n` has at most 18 digits. |
| `find_go_colon`, `find_str_colon` | The first ":" after a run of digits is found right after them. |
| `uncount_counted` | `uncount` reads `counted`'s strings back, after any prefix, when each length has at most 18 digits. |
| `kind_of_name_reads_kind_name`, `msgs_of_frames_reads_log` | A message kind's name, and a log's frames, read back. |
| `snapshot_parse_reads_text`, `snapshot_text_reads_back` | The snapshot's text parses as its state, and `snapshot_of`'s re-check passes. |
| `new_consensus_fits` | A new chain's state meets `snapshot_fits`. |

### core/agent.exp

The agent's policy before it signs an attestation (core/agent.soma's
`attest_duty`), and its one transaction in flight (`flush`). Statements about the pure duty, over the market's view the
node gives it; the model's answer and the checks' results are not modelled.

| Name | Checked statement |
|---|---|
| `getf_setf_other`, `getf_setf_same` | A field set reads back; other fields are unchanged. |
| `keeps_own`, `note_asked_keeps`, `enqueue_keeps`, `check_req_keeps` | What the duty's bookkeeping changes (the queue, the requests, what it asked) leaves the agent's name, attempts and denied paths as they were. |
| `asked_note_asked`, `asked_enqueue`, `asked_check_req` | A key noted as asked stays asked through queueing and a check request. |
| `attest_duty_never_attests_its_own_or_twice` | No attestation, check or model call for a merge it proposed, for its own bid, or for a merge it has a vote on. |
| `violation_attests_no_without_the_model` | A bid that breaks the policy (too many files, a denied path) gets at most a queued "attest no", and no check or model call. |
| `attest_duty_asks_once` | After the duty has run for a merge, running it again does nothing, until a failed model call counts an attempt or the merge is proposed again. |
| `release_inflight_me`, `submits_next`, `flush_submits_next` | Releasing what landed keeps the agent's name; each branch of `flush`'s queue match (a merge's or a mark's check, or a submission) meets `submits_next`. |
| `flush_one_in_flight` | When `flush` sends a transaction, none was in flight (after those that landed or sat 30 blocks are released), the one sent is recorded in flight, and it is at the agent's next nonce on the chain. That the chain accepts it at that nonce is the market's. |

### runtime/node_service.exp

What the node's service carries out for an image (runtime/node_service.soma;
docs/SHELL-IN-SOMA.md, "The node's service"). Statements about its
policy functions, not about Soma.Host's primitives or the programs it
starts.

| Name | What it says, and its limit |
|---|---|
| `refused_runs_nothing` | A request `sv_allowed` refuses runs only its log line. |
| `allowed_are_host_ops` | What it allows is one of nodeio's `service_op` operations. |
| `only_the_token_is_served` | A request served carries the node's token and decodes to a `service_op`; no claim about the token's secrecy. |
| `paths_stay_in_roots`, `roots_are_the_services` | A path it allows has no `..` part and is an absolute root (HOME/repos, HOME/inbox, a temporary path it made or its `.git`) or under one. |
| `path_operations_are_looked_at`, `symlink_never_followed` | Every read, write, listing or removal is probed below its root first, and one through a symlink runs nothing; the probe's own truth is Soma.Host's. |
| `processes_are_the_nodes_own` | A process it starts is its binary, the model, docker, its sandbox runner or its `cmd:` backend, from a path it allows, with its own environment's entries and a `cmd:` patch's. |
| `runs_are_cleanup` | A program run to its end is `rm`, `chmod` or `docker`. |
| `git_takes_no_options_of_its_own` | Every git argument is one of the host work's words, not an option, or a clone's git directory it allows. |
| `checkout_git_is_served`, `merge_commit_is_served`, `tool_checkout_is_served`, `model_launches_are_served`, `check_job_is_served`, `ci_is_served`, `cmd_backend_is_served`, `service_environment_is_served`, `cleanup_is_served`, `temporary_names_are_served` | What runtime/node_host.soma and runtime/node.soma ask, on paths it allows, is allowed: the restriction takes nothing the node needs, given the service runs with the image's flags. |
| `the_key_and_beyond_are_refused`, `programs_beyond_the_nodes_are_refused` | Examples on one service's world: the key, `..`, a root's sibling, git aliases and upload packs, `GIT_SSH_COMMAND`, `LD_PRELOAD`, another CI image, the clock. |

### runtime/node_path.exp

What a path probe answers (runtime/node_path.soma), for any answers the host's
lstat gives; the lstat itself is Soma.Host's, and a change between the
probe and the operation is outside it.

| Name | What it says, and its limit |
|---|---|
| `probe_only_looks` | Every operation it asks is a stat of one of the path's parts, joined in order. |
| `probe_finds_symlinks` | A part the stat calls a symlink, every part before it there, makes it answer "symlink". |
| `probe_found_every_part` | Answering neither "symlink" nor "none", every part is there and none is a symlink. |
| `probe_none_is_missing` | Answering "none", some part isn't there. |
| `probe_answers` | It answers "symlink", "none", "dir" or "file". |

### runtime/node_file.exp

How the binary writes its files (runtime/node_file.soma), for any answers the
host's one-call primitives give; what the file system does with a
rename or a sync is the host's.

| Name | What it says, and its limit |
|---|---|
| `failed_put_renames_nothing` | A put that fails ends the write before any rename: the file is as it was. |
| `whole_write_order` | When each step works: the mode looked at, the text put (synced when durable), the mode kept, the rename, then (durable) the directory synced. |
| `whole_write_only_renames_onto_it` | Every operation of a whole write is one of those; the only one on the file itself is the rename onto it. |
| `make_dirs_only_where_none` | A directory is made only where the host said none is, and never "", "." or "/". |
| `path_write_writes_its_file` | A path's write makes directories and writes that one file whole, nothing else. |
| `failed_save_ends` | A save that failed is said and the binary ends: it never answers as if written. |
| `remove_tree_starts_rm` | A tree's removal is one program started on its own, `rm -rf -- PATH`, the path its one operand; it always answers done. That rm removes the tree, later, is the host's. |

### runtime/node_git.exp

Git and programs as the binary runs them (runtime/node_git.soma), for any
answers the host's processes give; that a pipe's reads are the
program's output, and what the program does, are the host's.

| Name | What it says, and its limit |
|---|---|
| `read_out_reads` | Reading a program's output only reads its pipe. |
| `spawn_fed_none` | A program with no input is started alone, from /dev/null. |
| `spawn_fed_removes_its_file` | Input made into a temporary file: the text put in it, the start (only when the put worked) from that file, then the file removed, whatever the start answered. That the host removes it is the host's. |
| `spawn_fed_ops` | Starting a program with input does nothing but the start, a temporary file made, the input put in it and a file removed. |
| `exec_leaves_nothing` | A program that started: its start (with its input's file), reads of its pipe, the pipe closed, then the process waited for, nothing else. |
| `exec_failed_start_ends` | A program that couldn't start runs nothing more and answers not found, with why. |
| `exec_ok_only_on_exit_0` | It answers success only when it started and its wait said it exited with 0. |
| `git_env_keeps_host_git_out` | Git's environment holds the entries asked for, the fixed three, and the host's without any `GIT_` one. |
| `git_runs_only_git` | Git starts only "git", from where the binary is, with the fixed config flags and that environment; the rest is its input's file, its pipe and its wait. |

### app/cli.exp

Besides the commands' parsing and JSON examples:

| Name | What it says, and its limit |
|---|---|
| `up_waits_for_what_it_started` | `pantheon up` sets the stop on an interrupt or a terminate for the nodes it started, then waits for exactly those, in order. That the handler terminates them is Soma.Host's. |

## Remaining work

- Type the consensus, market and agent states and remove gradual escape hatches.
- Prove agreement across rounds (a lock carried from round to round) and
  through authenticated ingestion. `same_round_decisions_agree` covers
  decisions on proposals of one round, given that logged precommits are
  their senders'. The snapshot's round trip is proved
  (`snapshot_text_reads_back`); that a restarted node then acts on it is
  tested (`test/restart_lock.soma`, `test/e2e.sh`), not proved.
- Prove tree agreement through vote admission, settlement and shell application.
  Approval arithmetic and the finalize-origin result are only parts of this.
- Prove exact conflict clearing and rotation fairness. Of the agent's policy
  before signing, `attest_duty` and `flush` are proved (core/agent.exp);
  the leader's merge and approval paths (`lead`) and what a model's answer
  becomes (`on_answer`) are not.
- Use dependent types to represent validated paths and edits.

Keep proofs beside their programs, reduce assumptions reported by `soma explore`,
and never weaken tests to make a proof pass or weaken proofs to make tests pass.
