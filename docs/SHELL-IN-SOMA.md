# Moving the shell into Soma

Pantheon's decisions are Soma (`node.soma` and what it imports), but the
program around them is `shell.ml`, about 1,600 lines of hand-written OCaml
that `shell.definition` declares to Soma as four assumptions (`sha256`,
`hash_list`, `decode_tx`, `run`). The goal: as much of `shell.ml` as can be
is Soma, extracted with the rest, and OCaml is left only as thin bindings to
the libraries that do I/O: Unix (files, processes, sockets, time),
cryptokit (RSA, SHA-256) and yojson. Each binding is declared in a
`.definition` file, as `examples/example_projects/async_tasks` declares
Async's functions (GRADUAL.md, "OCaml modules").

What it buys: every line that moves is checked by Soma's kernel and can be
explored and proved about, and `soma explore main.soma` lists only the
bindings as assumptions, not a 1,600-line shell.

## Next: Soma owns the entry point and the loop

This replaces the order below and the "Next:" lines under "Done so far".

The first four pieces moved helpers bottom-up, and each one hit the same
wall. `shell.ml` is the program: `main := run ...` hands control to OCaml,
and Soma code imports `shell`, so `shell.ml` can't call Soma back. Every
moved helper became one more argument of `run` (nine now), and the last
two moves kept them in global refs (`soma_edit_once`, `soma_safe_path`) so
they needn't be threaded through every caller. Going on that way leaves
OCaml in charge, of the loop, genesis and all I/O, with more callbacks into
Soma. It isn't the goal.

So the dependency turns around first, top-down: Soma runs the program and
calls OCaml, and `shell.ml` becomes a library that never calls Soma. Then
each later piece moves a *caller* into Soma, and the helpers it used need no
wiring: they're plain Soma calls. The node is already shaped for it.
`node.soma`'s `step` takes an event and returns outputs (lists of strings),
and the shell is the loop that gathers events (sockets, timers, finished
jobs) and does what the outputs say (`feed` and `handle` in `node`).

One task each, in order:

1. **The command line in Soma.** `main.soma`'s `main` reads the arguments
   through a binding (`argv : unit -> list string`) and dispatches `init`,
   `keygen`, `edits`, `tx`, `up`, `plan`, `node` and the usage text in Soma.
   Each command stays an OCaml function, declared in `shell.definition`
   (`cmd_init : list string -> unit`, ...); `pantheon plan` calls Soma's
   `plan_open` directly. `run` is gone, and `node` is declared with what it
   still needs: the Soma helpers `run` takes today go to `node` instead,
   until step 3. After it Soma is the entry point.
   **One task, every command.** Moving one command's flag parsing into a
   Soma function that `shell.ml` calls (as a first bid of this epoch did for
   `keygen`) is the old direction: it adds an argument to `run` instead of
   deleting it. A command's own flag parsing can stay in its OCaml function
   for now; what moves is the choice of command, and `main`.
2. **The node loop in Soma.** `node` splits into an abstract handle,
   `Node.t`, and three bindings: `node_open : string -> list string ->
   Node.t` (home and flags: keys, genesis, replay, the listener), `events :
   Node.t -> list (list string)` (one `select` turn: what arrived on the
   sockets, the timers that fired, the jobs that finished, as `step`'s
   events) and `perform : Node.t -> list string -> unit` (one output: today's
   `handle`). The loop is Soma: it holds the state, calls `step` on each
   event, and performs the outputs in order. Two things stay exactly as they
   are: the consensus snapshot is saved (`save_snapshot : forall {C}, Node.t
   -> C -> unit`) before any vote is sent, and refused transactions are
   tracked as now. The loop never ends; a binding `forever : (unit -> unit)
   -> unit` (OCaml's `while true`) runs its body, so Soma needs no fuel or
   general recursion.
   **How to test the order.** Five bids on this step (Nov 10) were rejected
   because their tests timed a running node, polling `signed.log` and
   killing it, which can't show the snapshot came before the vote. Don't.
   What moves is `shell.ml`'s `feed`: run `step`, note a refused
   transaction (the state came back unchanged), perform the `decided`
   outputs, save the snapshot if it changed, then perform the rest. Write
   that order as a pure Soma function from the event, the old and new
   state and the outputs to a list of effects (perform this output, save
   this snapshot, refuse this transaction), and have the loop body only
   carry the effects out. Then the order is checked like `util.proof`:
   `Example`s that a vote event's effects save before they send, and that
   a refused transaction is remembered and dropped next time, and,
   past the floor, a theorem in a `.proof` for every event. The refused
   set can stay an OCaml table behind two bindings at the floor. The
   floor is the loop in Soma with its order checked by `Example`s; types
   can be loose (`Any` for the snapshot or the handle) where precise ones
   are a fight. When it lands, the bid rewrites the step 2 line in `.plan`
   for step 3.
3. **One record, not refs.** The Soma helpers OCaml still calls (`edit_once`,
   `contains`, `shell_safe_path`, `replace_all`) go to `node_open` once, as
   one record, instead of as `run` arguments kept in refs. Each one leaves
   the record when its last OCaml caller moves to Soma.
4. **`perform`'s cases, one or a few per task.** Each output's handling
   moves from `handle` into Soma, calling smaller bindings: sending (`send :
   Node.t -> string -> list string -> unit`), timers, the prompt a model call
   gets (with it `replace_all` and `plan_open` leave the record), applying a
   merge (with it `edit_once`), the CI check. Process, git and socket calls
   stay bindings.
5. **`events`' parsing.** Reading lines into events (`on_line`,
   `decode_tx`, the limits on lines and connections) moves to Soma; `select`
   and reading bytes stay bindings.
6. **Genesis, keys and the other commands.** `build_genesis`, `make_keys`,
   `cmd_init` and the rest move over the RSA, SHA-256, file and JSON
   bindings.

The end: `shell.ml` is bindings to Unix (files, processes, sockets, time),
cryptokit and yojson, none calling Soma, and `soma explore main.soma` lists
only those. Pure helpers still in `shell.ml` (`flatten_reply`,
`json_in_reply`, `shallow_json`, `chain_len`, `iterate`) move with their
callers, in 4 to 6, not as pieces of their own.

Past that, the end form is a unikernel. Once the node is Soma over a small
set of I/O bindings, those bindings can have a second implementation in
Soma's `Sandbox` (MirageOS), so an agent runs its node either as the binary
or as a unikernel, built from the same source and agreeing on every block.
The unikernel is the form to aim for: every line but `Sandbox`'s bindings is
checked Soma, and the node runs isolated (the bonus line in `.plan`). Keep
the bindings few and plain (bytes, files, sockets, time) with that in mind.
A unikernel starts no processes, and today the node runs git, model calls
and CI checks as processes: those go behind bindings for what they do
(apply edits and give a tree, ask a model, run a check), which the binary
does with a process and the unikernel asks a service for over the network.

## Two directions, and the unikernel

"Shell.ml to verified Soma" goes two ways at once, and the plan has items
for both, so a leader can take whichever moves the goal further:

- **Writing it in Soma at all** (breadth): steps 4 to 6 move OCaml into
  Soma with loose types. `Any` is fine at this floor, so a bid can move a
  lot: all of `handle` in one bid is welcome. Measured by the OCaml lines
  left in `shell.ml`.
- **Typing and proving what is in Soma** (depth): `Any` replaced by records
  and inductives where the code allows, and theorems for what the code
  promises (`order_effects` keeps every output once and puts decided ones
  before the snapshot; a merge needs n - f approvals). Measured by the count
  of `Any` and the theorems added.

**Where the whole of Pantheon runs.** Soma extracts to OCaml, so the binary
`main.exe` is already "Pantheon in Soma" for every part that has moved; at
the end of step 6, `shell.ml` is only the bindings named above, and the
binary is the Soma program plus them.

**The unikernel.** Soma builds a program that requires `Sandbox` into a
MirageOS image (`theories/Soma/Sandbox.v` in Soma: `io` as data, run by the
image). For the node to be one, its I/O must be one interface: a datatype of
the node's operations, as `Sandbox.io` is, which `shell.ml` interprets for
the binary and `Sandbox` interprets for the unikernel. `Sandbox` today has
printing, sleeping, a loop, the time of day, random numbers, arguments,
one-shot `serve` and `fetch` over TCP. The node also needs: peer links that
stay open (send and receive on a connection), a millisecond clock, storage
for the key and the block log, SHA-256 and RSA, and git, model calls and CI,
which the binary runs as processes and the unikernel would ask services for
over the network. Those are Soma's items, in Soma's own `.plan` (the market
governs Soma too); the interface is Pantheon's (the `U-1` line in `.plan`).

The interface so far is `node.soma`'s `node_op`, carried out by `io_do`
through one binding, `node_io` (shell.ml interprets the operation's wire
form, `io_wire`; `io_of_wire` reads it back, proved for every operation).
What a `Sandbox` interpreter of each operation still lacks:

| `node_op` | binary (shell.ml) | Sandbox lacks |
|---|---|---|
| `IoLog text` | a line on stdout with the time | nothing: printing (the time with the clock below) |
| `IoTimer ms event` | a timer list checked each select turn | a millisecond clock and sleep (Soma's "a millisecond clock") |
| `IoQueue event` | the event queue the next turn drains | nothing: a queue in the program's loop |
| `IoSendAll fields`, `IoSendPeer index fields`, `IoPeerSend peer fields` | sign, frame and buffer on the peer's TCP link | links that stay open (Soma's "links that stay open") and RSA signing (Soma's "SHA-256 and RSA") |
| `IoClock` | `Unix.gettimeofday`, returned as the second of `(true, now)` | a millisecond clock (Soma's "a millisecond clock"); Sandbox's time of day is not this clock |
| `IoStore height txs`, `IoSetHeight height`, `IoWriteStatus text` | append the block to blocks.log, note the height (dropping old resends), write status.txt | storage (Soma's "storage": named files on the image) |
| `IoSignVote slot vid fields` | note the vote and append it, synced, to signed.log | storage, with a synced append (Soma's "storage") |
| `IoTrackTx raw`, `IoMarkNonceFlood` | the own-transaction retry table (stamped with the time), the flood flag | nothing: state in the program (the stamp with the clock above) |
| `IoMergeApplied repo v`, `IoMergeDiverged repo entry` | the applied-version table, the divergence list | nothing: state in the program |
| `IoCheck id repo head edits` | the CI job: a fresh clone, the edits, the CI command as a process; its result comes back as a `check_result` event | services (Soma's "services": a CI service asked over HTTP POST, with a timeout) and git (applying edits to a tree) |

Not yet operations, still bindings of their own (the next parts of U-1):
the node's tables (reads, which need operations with a result, as
`Sandbox.io`'s binds have; the clock is the first of those), the
catch-up served table (`node_mark_served` carries a float, which has no
wire form yet), the resend memory (`node_remember_broadcast` carries two
lists, which one flat wire form can't read back without a count), the
snapshot (Soma's "storage" still), the merge's git work (reset, probe,
read, write, remove, commit), the listener and
accepted connections (links), SHA-256 and RSA (Soma's item), and git,
model and CI jobs (Soma's "services": `fetch` with a timeout and HTTP POST).

## The first pieces, bottom-up (superseded by the section above)

`shell.ml`'s sections, roughly from least to most I/O:

1. Pure helpers: `hex`, `replace_all`, JSON flattening (`flatten_reply`,
   `json_in_reply`), `plan_open`, `safe_path`, the edit matching in "edits"
   (`positions`, `apply_edits`' logic), `chain_len`/`iterate`.
2. The command line: parsing `pantheon init/keygen/genesis/status/tx/plan`
   and their messages, calling bindings for files and keys.
3. Genesis and keys: `build_genesis`, `make_keys`, `decode_tx`/`encode_tx`
   over RSA and SHA-256 bindings.
4. The node loop: `run`/`node`, sockets, timers, jobs and git, last.

Each task moves one piece, keeps the same behaviour, and leaves the rest
where it is. A piece that would need a binding Soma can't express yet is
worth a note in this file rather than a workaround.

## Step 4 is complete

Every output, including `llm`, is selected and interpreted by Soma's
`perform_output`. Startup/replay uses `perform_outputs` through `run_boot`,
and the live loop uses `carry_effect` through the same `perform_output`.
`LlmRequest` calls `perform_llm`; held calls return through `llm_call`, which
uses the same `prompt_assemble`. There is no OCaml `perform`/`handle` prompt
builder, and neither `replace_all` nor `plan_open` is a shell callback.

For model requests, the native bindings that remain are `node_llm_budget`
(increment/read the count and maximum), `node_limit_info` (read limit state),
`node_float_text` (format a float), `node_llm_hold` (store a raw request),
`node_token` (random fence token), `node_repo_names`, `node_ls_files` and
`node_head_file` (checkout metadata and contents), and `node_llm_start`
(start the process/inbox request, returning raw output immediately on startup
failure). Logs, event queues and the clock use `node_io`. Soma chooses the
budget/hold/ask branch, selects the optional tool checkout with
`llm_checkout`, and formats every prompt and log line. Only patch requests
whose context names a governed repository receive that checkout; the native
model binding creates the selected checkout and keeps its git directory
outside the writable worktree. The three
remaining helper callbacks are `edit_once`, `contains` and `shell_safe_path`;
they serve edit/command code and never assemble model prompts.

`test/prompt-assembly.sh` runs fixed inputs through the actual Soma functions,
including a mixed open/done/dropped plan and all placeholder substitutions.
It also pins complete leader draft, leader pick, bidder and attestor prompt
bytes with SHA-256 goldens, including defanged placeholders inside untrusted
text. Its `.proof` checks the fixed assembled result in Soma and proves the
plan's length bound, ordered-prefix property and open-source membership.
These checks use no running node or timing. Steps 5 and 6 and U-1 remain
separate work; this status does not mark `.plan`.

## Done so far

- Step 5, unchecked repository reasons: the shell reports a raw
  `check_unchecked_repo` fact with the repository and scope membership.
  Soma's `check_unchecked_reason` chooses the scope or `--no-check`
  explanation and `check_unchecked_repo_event` constructs the abstention.
  `test/check-unchecked-reason.sh` checks exact reasons, result fields and
  the live fact interpreter on deterministic inputs. The native check
  eligibility gate and process orchestration remain; this is partial work.

- Step 5, held-request event construction: taking held requests returns raw
  typed tuples through the storage bindings. Soma's `held_request_event`
  and `held_one_events` construct `llm_release` events, preserving prompt
  bytes and context order; an absent request gives no event. The shell no
  longer constructs these events. `test/held-events.sh` checks exact fixed
  results; `test/event-boundaries.sh` checks framing, admission, oldest
  selection and peer/inbox classification. This is a partial step 5 bid;
  the remaining native orchestration still needs its final audit.

- Step 5, the --backend flag: the shell feeds the raw string. Soma's
  `backend_kind_name` turns "scripted" and "scripted:" plus a suffix into
  the scripted kind, and anything else, including "scripted:" alone, into
  llm. `backend_behavior_event` keeps only a longer "scripted:" suffix,
  after the other agent flags. `test/backend-flag.sh` checks those cases.

- Step 5, connection counts: an accepted socket's `conn_offer` event
  carries its host and the hosts of the connections held at that moment;
  Soma's `conn_offer_counts` counts how many share the host and how many
  there are, and `conn_offer_decision` hands those to `admit_decision_of`.
  The shell no longer counts connections: it lists hosts, holds the
  socket, and carries the mode out. The counts are taken at accept time,
  as before. `test/conn-offer.sh` checks fixed host lists at and past
  both caps, with no running node.

- Step 5, a check's result event: `check_result_event` chooses the
  `check_result` event's fields in Soma (ok "true", "error" for a failure
  at this node's own stage "node", "false" for the bid's), and
  `push_check_result` queues it through the node's queue operation. The
  shell's `push_check_result` and the `node_check_result` binding are gone:
  a repository this node doesn't check comes back as a raw
  `check_unchecked` fact that Soma makes this node's own failure. Turning
  control characters into spaces stays a byte map binding
  (`node_plain_text`), so a large failed check's output never becomes a
  list of characters. `test/check-result-event.sh` checks the fields and
  the sanitizing through the binding.

- Step 5, a check's output: the shell queues the raw output as
  `check_apply_out` (request, checkout, CI command, text). Soma's
  `check_apply_plan_of` keeps the old split: an output that starts with
  `!` is `check_failed` (so `check_apply_stage` still says whose fault,
  from the node's own signals), and anything else is the trimmed tree.
  The bad-tree fault still logs and substitutes sha256("lie" ^ id)'s
  first 40 hex characters. No CI command queues the success
  `check_result` on this turn; a command asks `node_ci_launch`, which
  only strips `.git`, runs the sandbox or docker, and queues `ci_done`.
  The refusal for `--no-check` or an excluded repository still happens
  before the check job starts. `test/check-apply.sh` checks fixed
  outputs, including the lie hash against SHA-256.

- Step 5, goal files at startup: the shell no longer splits a `--goal`
  file. It feeds the bytes ("" when the file is missing) as one
  `goal_text` boot event, and `goal_events` (through `log_lines`, the
  same split as blocks.log) turns each nonempty line into an
  `agent`/`goal` event in order, among the other boot events.
  `test/goal-lines.sh` checks fixed texts. `.plan` is not marked.

- Step 5, log lines at startup: the shell no longer splits blocks.log or
  signed.log. It hands over each file's bytes ("" when it is missing):
  blocks.log as one `block_log_text` boot event, which `boot_expand` turns
  into the old `block_log` events at the same place, and signed.log through
  `node_signed_text` (it replaces `node_signed_lines`). Soma's `log_lines`
  splits them at each newline and drops empty lines, as the old
  `String.split_on_char` and filter did, reading by offset (`split_lines`).
  `test/log-lines.sh` checks fixed texts: a missing file, a final newline or
  none, empty lines, a line cut short, a carriage return, the events' order,
  and a 20000-line log.

- Step 5, genesis.json at startup: the shell feeds the file's text as one
  `genesis` boot event; Soma's `boot_expand` turns it, through the JSON
  token binding and `genesis_events`, into the old boot events in the old
  order (the roster, tips, block_ms, params in file order with repeats,
  repositories, excludes), first key winning as Yojson's member did. The
  walks share one fuel bound and skip each value once, so a wide genesis
  costs linear work, with no cap on the number of agents, params or
  excludes. What the old reads refused (a name, tip or param that isn't a
  string, a block_ms that isn't an int, a non-string exclude, params
  missing) stops the start through `node_fail`. `test/genesis-boot.sh`
  runs real texts, including 12001 params and excludes;
  `test/genesis_boot.proof` checks token streams.

- Step 5, job buffer storage: output chunks now live in node_state's
  jbufs, through job_buffer, job_remember and job_forget. job_bytes uses
  that state with the existing job_feed cap plan; job_outputs threads the
  state, resolves a completion's output and forgets it before calling the
  callback at its original queue position. The shell only reads bytes and
  reports wait facts; its jchunks and buffer bindings are gone.
  test/job-buffer-state.sh checks isolated jobs, replacement, removal and
  independence from peer buffers on fixed inputs. The existing job-feed
  tests continue to check framing and cap behavior. This is partial step 5.


- Step 5, Codex reply files: the callback queues only a process result and
  reply path. Soma's `codex_file_reply` applies the process-failure guard
  before opening the file through the existing `fs_read_text` binding,
  then removes it after resolving the text. Failed jobs never open it;
  successful empty files and missing-file errors retain their behavior.
  One small cleanup binding returns the resolved text so extraction keeps
  read-before-remove order. `test/codex-file-guard.sh` has fixed pure cases
  and actual FIFO, regular, empty and missing files, with no running node.

- Step 5, local inbox acquisition: Soma's `poll_inbox` decides the strict
  one-second interval and exact `.json` suffix, preserves directory order,
  maps read failures to empty text, and interprets a typed plan that queues
  `inbox_file` before removing each file. The timestamp is stored before
  listing and the shared turn clock is reused; dial/resend still precede
  inbox work, which precedes timers and select. Native bindings only read
  metadata, stamp, list, read and remove. New `test/inbox-poll.sh` checks
  fixed inputs without a running node. The replay-count getter also reads
  the count after Soma boot replay, fixing the existing crash test's
  missing replay announcement (the old handle captured zero at creation).

- Step 5, transaction members: `tx_parts` and `tx_parts_of` in
  market.soma read agent, nonce, fields and signature from the shared JSON
  token binding. Each of the four member lookups spends one token budget
  through nested skips, so wide objects take linear work. First duplicate
  keys win, including wrong kinds. The native transaction member parser
  and its binding are gone. Byte and shape guards still precede tokenizing,
  and nonce validation still precedes signature verification.
  `test/tx-members.sh` checks fixed real JSON, including 20000 unrelated
  members, and `test/tx_members.proof` checks tokens and the nonce guard.
  This is a partial step 5 bid; the plan remains open.

- Step 5, a peer line's members: `from`, `sig` and `fields` are read in
  Soma (`peer_line_parts`, under `node_line_parts` over the
  `node_json_tokens` binding) with Yojson.Safe.Util's old rules: the
  first matching key wins, and a missing member, one of another kind, a
  non-string in `fields` or a non-object is no event. One walk over the
  top-level members skips each value with one shared fuel (every step
  uses a token), so a wide object is linear work, as the old member
  reads were. The shape scan still runs first and the signature check
  still comes after the own/refused drop. The OCaml `node_line_parts`
  binding is gone. `test/peer-members.sh` checks real lines, including
  20000 unrelated keys before the three that count, and
  `test/peer_members.proof` fixed token streams.

- Step 5, a reply's braces: where a model reply's JSON object starts and
  ends (the first `{` and the last `}`, by byte offset) is found in Soma by
  `reply_open_at` and `reply_close_at`, one tail-recursive `char_at` scan
  each way with no substring per step, still only after the output-cap
  check. The `node_reply_open` and `node_reply_close` bindings are gone;
  the shell only reports the cap and yojson's tokens. `node.proof` checks
  the offsets, and `test/reply-braces.sh` checks them on fixed inputs
  (none, only one brace, a close before the open, several objects, a
  200 KB reply) and the fields they lead to.

- Step 5, signed.log at startup: the shell only reads the file's
  nonempty lines (`node_signed_lines`); Soma's pure `signed_log_entry`
  makes each a vote (slot, value id, fields through the JSON token
  binding), a line cut short (no vote after the slot, a value id neither
  empty nor 64 bytes, a vote that isn't a JSON list of strings: logged
  with the old text and skipped) or nothing (no space). `restore_signed`
  notes each vote through `node_signed_restore` before replay, and
  `signed_needs_snapshot` refuses to start, through `node_fail`, when
  votes were read and there is no consensus.state, as before. The OCaml
  parser is gone, and so are the shell's unused `job_how` and `exit_code`
  (Soma's `ci_job_how`, `ci_exit_code`) and the dead `conn_buffer` branch.
  `test/signed-log.sh` and `test/signed_log.proof` check fixed lines.

- Step 5, peer buffer storage: a connection's retained read chunks now
  live in Soma's `node_state` (`pbufs`, through `peer_buffer`,
  `peer_remember` and `peer_forget`), not in the shell's connection
  record. The `node_conn_buffer` and `node_conn_store_buffer` bindings
  are gone; the shell only reads bytes and reports `peer_closed` when
  it closes a descriptor, so Soma drops that connection's chunks.
  Closing for the byte cap and evicting the quietest connection also
  forget them in Soma.

- Step 5, framing checks: `peer_feed` packages each read's complete lines,
  retained chunks and strict retained-byte cap verdict in a typed record.
  The live `peer_bytes` branch uses that same pure plan, storing the partial
  and queueing complete lines before carrying out a close. New
  `test/peer-feed.sh` checks split and multiple lines, empty lines, malformed
  input, trailing partials, both cap edges, and a completed line followed by
  an over-cap partial, without a running node. Buffer storage still lives
  behind the native connection bindings; this does not complete step 5.

- Step 5, part: a check that fails before CI (applying the bid's edits)
  goes to Soma as a `check_failed` fact; `check_apply_stage` makes it the
  bid's (the check's own exit 1, or a signal) or this node's (it couldn't
  run, or another exit code), from the node's own signals only, and
  `perform_check_failed` logs and queues the result as before.

- Step 5, part: a CI check's outcome is Soma's. When the CI run ends the
  shell queues a `ci_done` fact (request, tree, memory budget, runner, raw
  output); `ci_outcome` decides passed, whose a failure is (this node's
  when the runner didn't start or exited with a code of its own, 1 to 127
  other than the bid's 86 and timeout's 124; the bid's otherwise) and why
  (the memory or time budget, an output cap, or the output's last 400
  bytes on one line), from the node's own exit codes only, never what the
  bid printed; the shell logs and queues `check_result` through
  `node_check_result`, which still makes `why` plain text.

- Step 5, part: job deadlines and which timers fire are Soma's.
  `job_should_expire` is the old strict test (elapsed greater than the
  limit, and not already stopped). `timers_due` keeps a deadline at or
  before the turn's clock and leaves the rest in list order; `sort_timers`
  orders the due ones as the shell's sort did (earliest deadline, then the
  event list, equal events in the stored order). `select_wait` is the old
  fifth-of-a-second cap, the gap to the next timer, or no wait when the
  queue already has an event. `node_tick` dials, resends and reads the
  inbox, arms that clock, then selects. The shell samples one clock
  reading for the turn, stores the timers and jobs, and signals only the
  job Soma names. Select and reading bytes stay in the shell.
  `test/clock-arm.sh` checks these on fixed inputs, with no running node.
  `node.proof` checks the same edges and proves the due timers are exactly
  the partition, that a stopped job is not stopped again, and that a
  queued event does not wait. Step 5 is not marked complete.

- Step 4, llm: Codex output selection is Soma's `codex_reply_of`: a
  process failure wins over the output file, a successful file read keeps
  its exact bytes (including empty), and a missing file gives the existing
  error. The shell reports the process result and file-read facts before
  cleanup; immediate startup failures and completed jobs use the same
  `model_output_events` path. `test/llm-codex.sh` checks eight pure results.

- Step 4, llm (part): grok's reply is read in Soma. The shell hands back
  curl's raw output like any backend's; `model_reply_events` takes
  `choices.0.message.content` from the yojson binding's tokens
  (`grok_content`, over `json_member`, `json_first` and `json_skip`, with
  Yojson.Safe.Util's old rules: the first matching key, a string content
  only), and otherwise gives `llm_error` with "grok: " and the output's
  first 300 bytes, never a limit hold, as before. `test/llm-grok.sh`
  checks it on fixed tokens. Left in shell.ml: codex's output-file read.

- Step 4, llm (part): a model job's launch is completed in Soma. For a
  cmd: backend, `tool_job_of` decides the time limit (1200 s without a
  tool checkout, 1800 s with one, 600 s when its clone failed), the
  `PANTHEON_WORKTREE`/`GITDIR`/`REPO`/`BIN` entries placed before the rest
  of the environment, and the directories removed afterwards; the shell
  only makes the checkout (`node_tool_checkout`) and names its own binary
  (`node_self_exe`). For grok, `grok_request` checks `XAI_API_KEY`, writes
  the header text and the JSON body with `GROK_MODEL` or grok-4.7 (quoting
  through `node_json_string`); the shell writes the header file and still
  reads grok's reply. `test/llm-launch.sh` checks these on fixed inputs.

- Step 5, part: a job's output bytes are accumulated in Soma. The shell
  reads a chunk from the job's descriptor and hands it over as a
  `job_bytes` event; `job_feed` appends it to that job's chunks and, past
  the output cap, keeps the last 64 KiB (the tail a failed check shows)
  and says the job is over. `buffer_over` is that test. The shell stores
  the chunks Soma returns and signals the process once (`node_job_flood`);
  it no longer trims the buffer or compares it to the cap. `job_result`
  still formats the outcome, and `node_job_complete` still runs the
  callback at the completion's original queue position. `node.proof`
  checks a line split across chunks, several lines in one chunk, an empty
  line, a trailing partial, a malformed chunk kept without an event, and
  the cap at and past its edge, and proves the under-cap append, that the
  over flag is `buffer_over`, the tail, and that two under-cap reads join
  to the same bytes. `test/job-feed.sh` runs those fixed results. Job
  deadlines and timer scheduling remain native; step 5 is not marked complete.

- Step 5, part: the node's inbox of local transactions is read in Soma.
  The shell only lists `inbox/*.json`, reads each file and removes it,
  handing Soma an `inbox_file` event; `inbox_tx` turns a JSON list of
  strings (through the JSON token binding) into the `local_tx` event, and
  anything else is logged as malformed, as before. Job completion outcomes
  and the output cap have also moved; job deadlines remain native.

- Step 5, part: a completed process is a `job_finished` fact, carrying its
  identifier, wait status, timeout/flood metadata and output. Soma decodes
  this into the typed `job_status`; `job_result`, `job_failure_reason` and
  `job_failure_tail` decide empty-success `pending`, exact success bytes,
  error prefixes, exit/signal/stop reasons, flood-over-timeout precedence,
  and the final 3000 diagnostic bytes. Those decisions left `shell.ml`.
  `node_job_complete` invokes the stored callback with Soma's result before
  its cleanup, preserving output-file reads, and returns queued events at
  that completion's original position. `job_outputs` interprets generated
  model replies before stepping the turn's events, as before. Native code
  still waits for processes, decodes platform signal numbers, holds the
  callbacks, and performs cleanup. There are no new helper callbacks into
  Soma or `Any` values at this boundary.

  `test/job-completion.sh` checks 21 fixed Soma results, including success,
  exits, signals, stops, flood/timeout precedence, exact tail boundaries,
  split peer chunks, multiple/empty lines, malformed peer input and the
  strict kept-buffer cap. Its `.proof` includes exact-result Examples and
  general success-byte and failure-priority theorems. This is a partial
  step: job deadlines and timer scheduling remain native; the output cap
  moved in the entry above. Step 5 is not marked complete.

- U-1, part: the node's effects that write (a log line, a timer, an
  event queued for the loop, a send to every peer, to the peer at an
  index or to a peer by name) are values of `node_op` in `node.soma`.
  Every place that called `node_log`, `node_timer`, `node_push`,
  `node_send_all`, `node_send_peer` or `node_peer_send` now builds an
  operation and carries it out with `io_do`; those six bindings are gone,
  and shell.ml's `node_io` is the one interpreter. `action_io` and
  `output_io` give the operation a plan's action or an output is, and
  `node.proof` checks them on concrete plans and proves each is carried
  out as exactly its operation, and that the wire form reads back.
  The clock is the same interface: `IoClock` wires as `["clock"]`, and
  `node_io` returns `(true, Unix.gettimeofday ())`; `io_now` is that
  second component, and the old `node_clock` binding is gone. Effects
  still return `(true, 0)` and `io_do` keeps the first component, so the
  call is not dropped. Storing a block, setting the height and writing
  status.txt followed, and then the signed-vote log (`IoSignVote`), the
  own-transaction table and flood mark (`IoTrackTx`, `IoMarkNonceFlood`),
  a merge's records (`IoMergeApplied`, `IoMergeDiverged`) and the CI
  check request (`IoCheck`): `node_remember_vote`, `node_track_tx`,
  `node_mark_nonce_flood`, `node_merge_set_applied`,
  `node_merge_note_diverged` and `node_run_check` are gone. Left: table
  reads, the served and resend tables, the snapshot, the merge's git
  work, and model jobs (see "Two directions, and the unikernel").

- Step 5, connection and line limits: an accepted socket reaches Soma
  as a `conn_offer` event carrying its per-host and total counts;
  `admit_decision_of` refuses at the per-host cap, evicts the
  connection `oldest_conn` names (the quietest, first of equals) at
  the overall cap, or admits it, and the shell only holds the offered
  socket and carries the mode out. After a read, a `conn_buffer` event
  reports the buffered bytes and `buffer_over` applies the cap Soma is
  given as a decimal string (no unary literal), closing through a
  binding. `node.proof` checks both caps at and past their edges and
  the oldest choice. Peer framing and parsing are in Soma. Job output
  caps are in Soma too (`job_feed`); job deadlines and timer scheduling
  remain native.

- Step 5, raw peer lines: socket framing queues a raw line. Soma applies
  the depth/item scan before the Yojson member binding, assembles sender,
  signature and field metadata, then uses the existing own/refused-before-
  verify path. Invalid lines return the state immediately without running
  consensus comparisons. The old `on_line` and global `soma_shallow_json`
  callback are gone; `node_open` no longer receives a scan callback.
  Examples and `test/peer-raw.sh` cover shape limits, bad members, exact
  fields and own/refused flags without racing a running node. Connection
  admission and buffered-line byte-limit decisions subsequently moved too.

- Step 5, part: `decode_tx` is Soma (market.soma). It refuses a raw
  transaction over the byte cap or not bounded JSON (`tx_shape_ok`, the caps
  as decimal strings), one the shell can't read as a transaction's JSON, one
  whose nonce isn't 1 to 17 digits (`nonce_ok`, before any signature is
  checked) and one whose signature doesn't verify (`tx_decision`). The shell
  only reads the JSON's members (`tx_parts`) and checks the signature
  (`tx_verify`). Left of step 5: the limits on lines and connections.

- Step 5, part: a model reply's JSON is decided in Soma. `json_in_reply`
  takes the job-output cap and the byte offsets of the first `{` and the
  last `}` as decimal strings (the cap is about 4 MB, so it is not a unary
  nat) and keeps the old guards: too long, a missing brace, the close not
  after the open, or `shallow_json` at depth 4 and 4096 items, and there
  is no object. `flatten_reply` turns the yojson binding's tokens into the
  old key, value, ... list (dotted names, list indices, left to right).
  The shell only reports the cap, finds the two bytes, and tokenizes;
  its `json_in_reply` and `flatten_reply` are gone. `node.proof` checks
  slices, nesting, absent objects and the flattened fields, and proves a
  reply with no object or past the cap never becomes a reply event, and
  that a parsed object becomes a reply with those fields. Left of step 5:
  lines into events (`on_line`, `decode_tx`, the line and connection
  limits).

- Step 5, part: what a model call's output becomes is decided in Soma.
  A finished model job comes back raw as an `llm_output` event (or at once
  from `node_llm_start` when the process couldn't start), and `node_tick`
  turns each into what it becomes (`job_outputs`, in order, before any of
  the turn's events runs, as the shell did when the job finished). Pure
  `reply_outcome_of` gives a hold, an error (with the old "no JSON object"
  and "empty" texts) or the reply's fields; `is_limit` (the limit words and
  429 as a number of its own), `reset_in` (Claude Code's "|deadline", "try
  again in" and "resets in" with their units), `limit_wait` and
  `limit_next_backoff` decide the hold, and Soma writes the LIMIT line.
  The shell keeps the limit's state (`node_limit_set`, `node_limit_clear`),
  reads a digit run with `float_of_string` (so big numbers cross as
  floats, not unary nat) and still parses the JSON: `node_reply_fields` is
  `json_in_reply` and `flatten_reply`. `node.proof` checks limit and
  non-limit texts, deadlines past and future, units, the backoff's cap and
  each outcome, with theorems that a reply with no JSON object or a failed
  job never becomes a reply event. Left of step 5: lines into events
  (`decode_tx`, the line and connection limits) and the reply's
  JSON (`json_in_reply`, `flatten_reply`).

- Step 5, part: a peer line is accepted or dropped in Soma. The shell
  parses the JSON and hands Soma the sender, signature, fields, and
  whether the line is its own or an already-refused transaction;
  `run_event` drops those without a verify (so refused transactions
  resent every few seconds never pay for one), verifies the rest
  through `node_verify_line`, and turns a verified line into its
  `tx` or `msg` event. `node.proof` checks the drops and both
  events. Left of step 5: `decode_tx`, the line and connection
  limits, and the reply JSON.

- Step 5, part: when held model requests go back is decided in Soma.
  `node_tick` asks `release_held` first each turn: pure `release_plan_of`
  releases none while the limit lasts, while a probe is out or when none
  are held, one (the probe) while the backoff is up, and all otherwise,
  with the same messages; they run as `llm_release` events first among the
  turn's events, oldest first, as before. The shell only keeps the held
  requests and hands over the oldest one or all of them. Left of step 5:
  lines into events, and a job's output (reply JSON, is_limit, reset_in).

- Step 4, llm (the last case): `perform_llm` decides the call budget and
  the rate-limit hold (`llm_gate_of`) and writes their log lines, and
  `prompt_assemble` fills `{{F}}`, `{{REPOS}}`, `{{PLAN}}` and `{{REPO}}`
  with Soma's `replace_all`, `plan_open`, `listing_text`, `plan_text_of`
  and `repo_text_of` (the 64 KB per file and 200 KB budget included).
  `repo_read_text` reads and truncates each context file before reading the
  next, so prompt assembly doesn't first retain every full context blob.
  The shell only counts calls, lists a checkout's files, reads a file at its
  head, makes a fence token and runs the model process. A request held
  for a limit is kept raw and comes back as an `llm_release` event, so
  Soma assembles its prompt again when it is asked, as before. `perform`
  and `handle` are gone: every output is decided in Soma. `replace_all`
  left the helper record and `plan_open` left `node_open`'s arguments.
  The subsequent step 5 work below also moved reply interpretation and
  held-request release decisions into Soma; native code decodes JSON
  members, reads completed jobs and stores the held-request state.

- Step 4, broadcast: `broadcast_plan` decides which vote is sent, the
  signed-vote log, and the per-peer equivocate and double-vote variants.
  Silence records the vote and sends nothing. The two-second resend repeats
  the messages Soma stored, and does not choose them again. OCaml only
  reads and writes the vote table and the sockets. Merge, llm and check
  followed; all step 4 cases are now complete.

- Step 4, status and submission: `status_output` assembles the status file
  from raw checkout heads, divergence records and limit metadata; the only
  shell operations read those values, convert a timestamp to local time,
  and atomically write the text. `submission_plan` selects the ordinary
  signed transaction and the one-time future-nonce fault's 600 extras,
  including logging, queue/send ordering and the flood marker. Signing,
  retry-table insertion and socket writes are small bindings; silent-mode
  suppression is selected in Soma. Both cases use `perform_output` during
  startup/replay and runtime, and their old `handle` branches are gone.
  `node.proof` checks exact status bytes, limit boundaries, log truncation,
  dispatch, flood ordering/count/range and silent sends. Merge, llm and
  check followed through the same dispatcher.

- Step 4, peer catch-up: `behind` now selects `CatchupPeer` in the shared
  Soma dispatcher. `catchup_plan` names the served-table write and bounded
  block reads in order; `catchup_send` selects an authenticated peer send
  only for present blocks, including empty blocks. The original two-second
  throttle, remembering silent/absent peers, and inclusive 51-block cap are
  preserved. `node.proof` checks exact plans and message fields, malformed
  arities, time/range boundaries, and missing/empty blocks. OCaml supplies
  only clock/table/metadata access and signing/socket writes. The other
  cases now also dispatch through `perform_output`.

- Step 4, partial: Soma handles `timer`, `log`, `reveal` and `decided`.
  `plan_output` selects their small bindings; pure `reveal_plan` decides
  when to withhold, queue a hash-chain link or do nothing, and
  `decided_plan` requests exactly one store for an unseen height. OCaml
  binds delay scheduling, logging, queue insertion, metadata/table reads
  and the synced block store. `node.proof` checks concrete binding plans,
  malformed outputs, withhold/bounds behavior, and duplicate decisions.
  To use the same interpreter during startup and replay, `node_open` now
  returns setup/replay events and the saved consensus as data; Soma runs
  the events, restores only a matching-height snapshot, and starts the
  node with decided outputs before its mandatory snapshot and votes after.
  `startup_effects` checks this order without timing a live process. The
  old `feed` loop and its state/step/checkpoint/restore callbacks are gone.
  The llm case above completed step 4. Helpers with remaining edit/command
  callers stay in their record.

- Step 4, merge: a decided merge dispatches in Soma (`perform_merge`). Pure
  `merge_gate_of` passes over an unknown repository, an applied version and
  a diverged checkout; `merge_edit_plan` and `merge_edit_apply` (Soma's
  `edit_once`) decide each edit; `merge_tree_check` compares the committed
  tree with the attested one. The shell only resets, probes, reads, writes,
  removes, commits and records. `apply_edits` stays in shell.ml for
  `check` and `apply-edits`.

- The helper callbacks (step 3) are one typed `shell_helpers` record in
  `util.soma`. `node_open` receives it once; the binding transports its three
  remaining fields as a product (`pack_helpers`), since `.definition`
  accepts products but not Soma record types. `shell.ml` unpacks it into a
  named OCaml record and threads it through edit and command callers.
  `edit_once` serves edit application/diff replay, `contains` serves URL
  resolution and CI error classification, and `shell_safe_path` serves path
  checks. `util.proof` checks all three packed callbacks on pure inputs.
  Prompt expansion calls `replace_all` directly in Soma; plan filtering
  calls `plan_open` directly there too.

- Command selection now lives in `main.soma`: `argv` excludes the executable
  name, and Soma preserves the command tails and the existing usage behavior.
  `run` is deleted. Command implementations are bindings in `shell.definition`;
  `plan` calls `plan_open` directly over `read_plan`. The existing helpers go
  to `cmd_node`; commands that also use edit or path helpers receive those
  same helpers, with no new Soma callback. `test/cli.sh` covers this boundary.
  Next: step 2 above, the node loop in Soma.

The following entries describe the earlier bottom-up moves and their wiring
at the time; their `run` references are historical.


- The node loop (step 2): `run_node` in `node.soma` holds the state and
  drives `step`; `shell.ml` binds only `node_open` (keys, genesis, replay,
  the listener, the setup feeds), `events` (one select turn), `perform`
  (one output), `save_snapshot`, `note_refused`, `take_state` and
  `forever`. The setup still feeds through the shell's old `feed` inside
  `node_open`; every running event goes through the Soma loop. Its order
  is `order_effects` in `node.soma`, a pure function from the event, the
  state before and after `step`, and the outputs to effects (perform this
  output, save this snapshot, refuse this transaction): decided outputs
  first, then the snapshot when consensus changed (`cons_eq`), then the
  rest; a refused transaction is one whose raw form did not enter the
  pool. `node.proof` checks that order with `Example`s (decided, snapshot
  and rest together; a refused and an accepted transaction; an empty
  step; steps with only some kinds; a vote saving before it sends), not
  by timing a node. Effects return `bool` and the loop keeps the new
  state only when they were carried out: a `unit` result is a value the
  extraction can erase, and with it the call. The handle is a string
  naming the shell's side; the snapshot crosses as consensus state and
  the shell still writes it only when it changed. Next: step 3 above.

- `plan_open` (piece 1, in part): now `plan_open` in `util.soma`, with its
  string helpers (`trim`, `split_lines`, `is_date_line`, `marked_line`,
  `truncate_line`). `shell.ml`'s OCaml version is deleted; `run` takes the
  Soma function as an extra argument (declared in `shell.definition`,
  passed in `main.soma`) and hands it to `node`, so the `pantheon plan`
  command and the node loop's plan prompts both use the Soma version.
  Still in `shell.ml` from piece 1, next in roughly this order:
  the edit matching (`matches_at`, `positions`,
  `replace_at`, and `apply_edits`' pure logic), `safe_path`'s OCaml copy
  (Soma already has one in `util.soma`), the JSON helpers
  (`flatten_reply`, `json_in_reply`, `shallow_json`), and
  `chain_len`/`iterate` (over the `sha256` binding).

- `replace_all`: now in `util.soma`, with `drop_str` and a bounded scan.
  The OCaml implementation is deleted. It initially crossed `run` as a
  callback; after step 4 it is called directly by Soma's `prompt_assemble`.
  Replacement remains literal, left-to-right and non-overlapping; inserted
  text is not scanned again. All shell patterns are nonempty (an empty
  pattern now leaves the text alone, rather than looping forever).
  Next: edit matching (`matches_at`, `positions`, `replace_at`, and
  `apply_edits`' pure logic). I/O stays in the shell.

- Edit matching: `positions` (the first two places at most), `replace_at`
  and `edit_once` (the text with its one occurrence of the old text
  replaced, `None` when it's missing or ambiguous) are in `util.soma`.
  `shell.ml`'s `matches_at`, `positions` and `replace_at` are deleted.
  `run` gets Soma's `edit_once` and `contains` as two more arguments and
  stores them in two refs at its start, so `apply_edits`, `hunk_edits`,
  `repo_url`, `check_tree` and the node loop use them without threading
  them through every caller. `apply_edits` tells "isn't in the file" from
  "appears more than once" with `contains`. Nat doesn't cross the binding
  boundary (extracted code's `nat` is abstract to `shell.ml`), so the
  bindings take `option string` and `bool`, not positions.
  Next: `safe_path`'s OCaml copy (use `util.soma`'s, checking the two agree
  on `test/edits.sh`'s cases first), then the JSON helpers
  (`flatten_reply`, `json_in_reply`, `shallow_json`), then
  `chain_len`/`iterate`. I/O stays in the shell.

- Shell path validation: the OCaml `safe_path` logic is deleted and all its
  callers use `shell_safe_path` in `util.soma`, passed through `run` and
  stored in a ref like the edit helpers. The existing Soma `safe_path`
  agrees on the edits script's cases, but differs on other paths: it rejects
  filenames containing `..`, permits NUL, and misses mixed-case `.git`.
  `shell_safe_path` preserves the shell's exact policy without changing the
  market's policy: only whole components are forbidden, ASCII case is ignored
  for git metadata, and NUL and backslash are refused.
  Next: the JSON helpers (`flatten_reply`, `json_in_reply`, `shallow_json`),
  then `chain_len`/`iterate`. I/O stays in the shell.

- `shallow_json`: the bounded string scan now lives in `util.soma`.
  `run` installs it in a ref through `shell.definition`, including for
  `decode_tx`, model replies and peer messages. The thin OCaml wrapper keeps
  depth 4 and the default `max_int` item budget; replies still use 4096.
  Limits cross the binding as decimal strings because extracted `nat` is
  abstract to the shell. String escapes, container/colon/comma spending,
  and even negative depth on malformed input retain the original behavior.
  It walked the text a character at a time, a quadratic scan of every
  peer message and transaction, and now reads it by offset (`char_at`).

The LLM migration's callback boundaries are also checked in
`test/llm_prompt_isolation.proof`: an empty context is independent of the
task-repository reader for every prompt and every pair of readers, and
plain/empty prompts are independent of all context readers. Fixed checks
record replacement order: earlier fence markers inserted by a later section
stay literal, while later section markers still expand. No runtime move is
needed for these laws; the shared Soma assembler already implements them.

## How a bid is judged

Soma is gradually typed (Soma's GRADUAL.md): code with loose types (`Any`)
runs, with a cast checked when the value is used, and precise types and
theorems can come later. So each step has a floor and room past it:

- **The floor** is the move done and working: the code is in Soma, it
  builds, the tests pass, and what the step says stays exactly as it is
  (an order of effects, say) is checked by `Example`s on a pure function.
  Types may be loose where precise ones are a fight, and there need be no
  theorems. A bid at the floor is mergeable.
- **Past the floor** is welcome, not required: precise types instead of
  `Any`, and theorems in a `.proof` about what the moved code does. Among
  correct bids the leader prefers the one that goes further.
- What fails either way: an `Admitted`, an axiom or a cast escape
  (`unk`, `err`) the CI policy refuses (`deploy/ci-command.py`). Leave a
  theorem out rather than admit it.

The rest:

- `soma build main.soma` builds, and the market's CI passes: the fast tests,
  and every `test/*.sh` the bid adds (docs/SANDBOX.md, "What CI runs"). The
  scenarios are the specification; a bid that needs a new one writes it as a
  new `test/NAME.sh`, which CI then runs, since a test that's there can't
  change. A bidder runs `test/e2e.sh` in its checkout if it can and says in
  its note whether it did; a sandboxed bidder may not be able to open
  sockets, and not having run it isn't a reason to reject a bid whose other
  checks pass.
- `soma explore main.soma` lists no new escape hatch the move didn't need,
  and the moved code adds no `Admitted` or axiom (the CI policy refuses them).
- Numbers that may be large are `N` or OCaml ints by extraction, not unary
  `nat` (main.soma already extracts `nat` to OCaml ints).
- Long text isn't walked a character at a time. Strings extract to OCaml's
  (`ExtrOcamlNativeString`), where matching `SCons c r` copies the rest of
  the string and building `SCons c r` copies `r`, so a walk is quadratic,
  and one that isn't tail recursive is a frame per character. Prompts,
  diffs and files run to hundreds of kilobytes: such code reads by offset
  with `util.soma`'s `slen`, `substr`, `char_at` and `find_str` (which
  `main.soma` extracts to OCaml's `String` functions), or folds over
  `chars s`, with an example in `util.proof` for what it computes. Before
  that change, one edit applied to `shell.ml` took 8 s; now it's under
  10 ms, and 0.03 s on a 940 KB file.
- Each task leaves `run`'s or `node`'s arguments no longer than it found
  them, after step 1 above: a new Soma helper OCaml needs goes in the
  record (step 3), not in a new argument or ref.
