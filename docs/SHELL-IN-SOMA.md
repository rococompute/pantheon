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

## Done so far

- The helper callbacks (step 3) are one typed `shell_helpers` record in
  `util.soma`. `node_open` receives it once; the binding transports its four
  fields as a product (`pack_helpers`), since `.definition` accepts products
  but not Soma record types. `shell.ml` unpacks it into a named OCaml record
  and threads it through callers, including the standalone commands; the
  edit, contains and path refs are gone. All four fields still have callers:
  edit application and diff replay use `edit_once`, URL resolution and prompt
  handling use `contains`, path checks use `shell_safe_path`, and prompt
  expansion uses `replace_all`. `util.proof` checks the record projections
  and calls all four functions from the packed value on pure inputs. The
  separate JSON scan callback still serves `decode_tx`; its existing wiring
  is outside this step. Next: step 4 above.


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
  The OCaml implementation is deleted; `main.soma` passes the Soma helper
  through `shell.definition`'s `run` argument to the node's prompt expansion.
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
