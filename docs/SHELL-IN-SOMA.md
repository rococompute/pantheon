# Moving the shell into Soma

Pantheon's decisions are Soma (`node.soma` and what it imports), and so is
the node's kernel (`node_kernel.soma`: its tables, peer links, signatures,
files and select), the host's work it asks for (`node_host.soma`: a
merge's git, the model's budget and limit, jobs, checks and CI) and the
edits machinery (`cli.soma`: applying edits, reading a checkout's changes
as edits, a bid's tree), the binary's network and jobs
(`node_net.soma`: its links, buffers, select, the service's socket and
the process table) and its git and programs (`node_git.soma`); what is left of the program around them is
`shell.ml`, about 395 lines of hand-written OCaml (it was about 1,600)
that `shell.definition` declares to Soma as four assumptions (`argv`,
`print_lines`, `node_io`, `forever`), with the crypto main.soma extracts
to Cryptokit. The goal: as much of `shell.ml` as can be
is Soma, extracted with the rest, and OCaml is left only as thin bindings to
the libraries that do I/O: Unix (files, processes, sockets, time) and
cryptokit (RSA, SHA-256). Each binding is declared in a
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
   bindings. (Done: `cli.soma`, below.)

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

The interface is `nodeio.soma`, a module with no shell under it: the
operations, `node_op`, and programs of them, `nprog` (`NDone a`, or
`NStep op k`: do `op`, then go on as `k` says on its answer), as a Sandbox
program is a value of `Sandbox.io`. The binary runs a program with
`node.soma`'s `run_shell`, through one binding, `node_io` (shell.ml
interprets the operation's wire form, `io_wire`; `io_of_wire` reads it
back, proved for every operation); `io_do`, the clock and the table reads
are one-operation programs run that way, and the output actions are
programs (`action_prog`, `actions_prog`). `nodeio.proof` says what a
program does whoever interprets it (`ntrace`, the operations carried out
for given answers; `nand_trace`), and `node.proof`'s
`single_actions_trace` that a list of one-operation actions does exactly
those operations, in order. Output handling is one program too (`output_prog`): the reads it needs
(the draw, a stored block, the height, the peer count, the vote signed at
a slot, a transaction's signed line, the check exclusions) are operations
whose answers carry data (`nanswer`'s list), asked in the program's
continuations after the operations before them, so they happen when they
did. The status file is a program as well (`status_prog`): the checkouts'
heads, the divergences, the clock, the model limit and, when a limit is
on, its end as a time of day, read in the old order (`node.proof`'s
`status_reads_in_order`). So is a decided merge (`merge_prog`): the
gate's reads, the checkout's reset, each edit's look at its path, read,
write or removal, and the commit are operations (`merge_trace`,
`merge_wrong_tree_diverges`). And so is a model call (`llm_prog`): the
budget, the clock and the limit for its gate, then a fence token, the
environment, the prompt's parts (each repository's listing, each .plan,
a task's files, read one at a time), a cmd: patch's tool checkout and
the process's start (`llm_over_budget_trace`, `llm_asked_trace`); the
prompt it assembles is `prompt_assemble`'s (`prompt_prog_assembles`,
`repo_read_prog_reads`). Every output is now a node program, and so is
what a model's output becomes (`model_output_prog`: the limit noted or
cleared, the request held, a codex reply file read and removed, a check's
output and the CI it starts), a finished job's outputs, each one's effects
before the next one's (`model_outputs_prog`; the extracted `flat_map` this
replaced ran them last first), and giving held requests back
(`release_prog`; `release_reads_first`). Lists of events and of held
requests cross the wire framed (`nio_frame_lists`, read back by
`nio_lists`: `nio_lists_reads_frames`). A turn of the event loop is one
program too (`node_tick_prog`, run by `run_shell` in `node_tick`): the
released requests, dialing and resending, the inbox's poll, the overdue
jobs and due timers, one select (`IoEvents`) and what its events become
(`run_event_prog`: a peer line's identity, refusal and signature checks,
connection admission, CI results, the inbox's transactions, each step's
effects carried by `carry_all_prog`). Startup is a program
too (`boot_prog`): signed.log read back (`restore_signed_prog`; refusing
to start, `IoFail`, when it has votes and there is no snapshot), the boot
events expanded (`boot_expand_prog`) and replayed (`run_boot_prog`, each
block remembered for catch-up with `IoRememberBlock`), the replay logged
and the start step carried (`start_node_prog`; `fresh_boot_reads`). So
`run_node` (node_shell.soma, with `run_shell`: the binary's own
interpreter, which the unikernel's build never sees) is the setup program
(cli.soma's `node_setup`), the runtime
built from it (`node_open`), the snapshot read back (`IoSnapshotLoad`),
then `run_shell` of the boot program and `forever` of the tick: every
effect the node has is a node operation but building `node_open`'s
runtime.
The resend write uses tagged `field`/value pairs followed by `alternate`
and the untouched second list. Values may themselves contain either tag.
Resend reads and the native table remain unchanged.
### One kernel, two runners

What a node keeps between operations, and how it carries them out, is
Soma, written once: `node_kernel.soma`'s kernel, which the binary and the
unikernel both run. `kernel_run` turns a node program into a program of
the kernel's eight primitives (nodeio.soma's `IoNetListen`,
`IoNetMailbox`, `IoNetConnect`, `IoNetSend`, `IoNetClose`, `IoFileRead`,
`IoFileWrite`, `IoFileAppend`: Sandbox's own, by name) and of the
operations it hands on as they are (logging, the clock, a time of day,
refusing to start, and the host's work: nodeio.soma's `service_op`).
Two runners carry that out: the binary's, `run_net` through shell.ml
(node_shell.soma's `run_node`), whose network and named files are
node_net.soma's over the host's sockets by name ("The binary's network"
below); and the unikernel's, `run_image` with Sandbox
(node_sandbox.soma's `run_node_image_at`), which asks the node's service
for the host's work.

The kernel keeps the tables (nodeio.soma's `nio_tables`: timers, the
queue, decided blocks and signed votes by key in AVL maps, resend
memory, served catch-ups, refused transactions, applied versions and
divergences), the genesis peers and the links it dialed to them, the
connections peers opened (offered, then admitted, evicted or refused as
node.soma decides), when it dials (once a second) and resends (every 2
seconds), the turn's clock reading, the snapshot text last saved (one
that hasn't changed isn't written again) and the peer lines it signed
since the last resend and at it, by their fields (a resend sends the
same lines again, so a line is signed once). It signs peer lines and
transactions with Soma's RSA (`nio_wire_line`, `nio_encode_tx`; the
"bad-sig" draw's line has 512 zeros), and writes blocks.log and
signed.log with the lines nodeio.soma's pure part makes (Yojson's, byte
for byte; `test/node-sandbox.sh` checks them with `soma run`, and builds
a unikernel that runs a node program with `soma build --no-image`). A
select (`IoEvents`) is the runner's mailbox (what came in on
connections: an offer, bytes, an end), then the host's events (its
jobs'), then the queue, drained.

| primitive | binary (node_net.soma, over shell.ml's sockets) | unikernel (node_sandbox.soma) |
|---|---|---|
| `IoNetListen address port` | bind and listen (not found: why) | `listen_mailbox port` |
| `IoNetMailbox ms` | one select on the listener, peers' connections, dialed links with bytes to write, and the host's jobs (whose output wakes it) | Sandbox's `mailbox` (a fifth of a second at most with a service: a job's output there doesn't wake it) |
| `IoNetConnect host port ms` | a non-blocking connect (a name is resolved at each dial) | `connect_within`, giving up after `ms` |
| `IoNetSend conn data` | buffered (64 MiB at most), written when the select says it can be | `send` |
| `IoNetClose conn` | close | `close` |
| `IoFileRead name`, `IoFileWrite name durable text`, `IoFileAppend name text` | the file in the node's home; written atomically, synced when durable; appended in one write, synced | the named file on the storage device |

The operations the kernel hands on: `IoLog` is a line with the time in the
binary, `print` in the unikernel; `IoClock` is `Unix.gettimeofday` in the
binary, Sandbox's monotonic clock in the unikernel (since boot, not the
time of day, so a model's reset time can't be compared with it yet), and
`IoLocalTime` is `Unix.localtime` or the stamp as it is; `IoFail` exits 1
with the message in the binary, and is printed in the unikernel. The
host's work (`service_op`: git in the checkouts, model calls and their
limit, CI and checks and their jobs, reply files, the inbox) is shell.ml's
in the binary, and the node's service's in the unikernel: with none, a
check is reported and comes to nothing, the checkouts are at their genesis
commits, the model has no limit, and there are no jobs, reply files or
inbox. The commands' operations (`IoPrint` ... `IoGitEnv`) are shell.ml's
and node_git.soma's (the unikernel prints, writes named files, and answers false to the rest:
it makes no keys and runs no git).

The commands are node programs too (`cli.soma`): `init`, `keygen`,
`genesis`, `up`, `status`, `tx`, `plan`, `edits`, `apply-edits` and
`check` decide in Soma (their arguments and messages, a new agent's
key.json, chain.json and public.json with the hash chain's tip, the
genesis's bytes and every check on them, written through a small JSON
value that prints as Yojson.Safe does) and do their I/O through the
operations above, which `node_io` answers with no node. `main.soma`'s `dispatch` runs them with `run_shell`; `pantheon node` is `run_node`. The `cmd_*` and
`read_plan` bindings are gone. A genesis is the same bytes either way:
the old binary and the new one, given the same parts, write the same
genesis.json. Two cases that crashed the old binary now say why:
`up` on a directory with no agents, and an edits file that isn't a JSON
list of strings. One known difference: a float in network.json's params
is written as the integer the node reads it as (Yojson kept its digits).

The consensus snapshot is Soma's text (node.soma's `snapshot_text`):
the state as frames of strings, each its length in decimal, ":" and
itself, after a header naming the format. It replaced OCaml's Marshal,
which a unikernel can't read and Soma can't check. Reading it back is
strict (`snapshot_of`: the text must be exactly what `snapshot_text`
writes for the state it reads), and a node whose consensus.state Soma
can't read refuses to start, as it did when Marshal failed: a node that
signed votes must not start without its lock. A consensus.state written
by an older Pantheon is refused so; such a network wants a new genesis.

The node's setup is a node program too (cli.soma's `node_setup`, run
with no node): the home made absolute and private, genesis.json,
key.json and chain.json read and checked, the PANTHEON_BYZ fault
injection noted, the node's flags parsed (a --goal's file read in), the
governed repositories checked out and checked against the genesis's
trees, and which already carry a merge. It gives `node_open` framed
data: the settings, this node's key, its exclusions, the repositories it
can't check, CI commands by repository, the agents, the repositories,
those still at genesis, then the boot events. `node_open` only builds
the runtime from it: its tables, the listener, jobs and closures (since
then it takes only the home, for the network's state: the kernel reads
the rest, its host work included). A home
whose key.json names no genesis agent, and a --max-llm-calls that isn't
a number, now say so (the old binary crashed on both).

Not yet operations, still bindings of their own (the next parts of U-1):
`node_open`'s runtime (Soma's "storage" still), the listener and
accepted connections (links), and git, model and CI jobs (Soma's
"services": `fetch` with a timeout and HTTP POST).
(Since done: the links are operations, and so are git, model and CI
jobs, which a unikernel asks its node's service for: "The node's
service", below; and the jobs themselves are the kernel's, over process
primitives: "The host's work", below.)

SHA-256 and RSA are Soma's (`Soma.Crypto`, Soma's item): `sha256` and
`hash_list` are `util.soma`'s, no longer bindings, so the kernel computes
them and a unikernel runs them. The binary extracts them to Cryptokit's
(main.soma), the same function in C: Soma's extracted SHA-256 is about a
tenth of its speed, which slowed e2e from 114 s to 130 s. The test checks
the two agree on known answers.

Every signature is checked by Soma, in the binary as in the unikernel:
a transaction's in `decode_tx` (`nio_tx_verify`, with the agent's key from
the market's own table, filled by the boot events `["chain", id]` and
`["key", agent, size, n, e]` that `node_setup` gives) and a peer line's in node.soma
(`nio_line_verify`, with the sender's key from `IoPeerKey`, which the
kernel reads from the setup). Keys are made with e = 65537 (`make_keys`),
which Soma checks in about 1.6 ms. A genesis made before has Cryptokit's
random 2048-bit public exponents, which take about 90 ms each: such a
network still works, slowly, and wants a new genesis.

Signing is Soma's too, in the kernel (`nio_sign`, through `nio_wire_line`
and `nio_encode_tx`): about 12 ms a signature with a 2048-bit key in the
unikernel. The binary extracts `nio_sign` to Cryptokit's (main.soma,
`Shell.rsa_sign_bytes`), as it does SHA-256: PKCS#1 v1.5 is
deterministic, so it is the same signature, in about 1 ms. With Soma's,
the e2e `future-nonce` flood (600 transactions, each signed and resent)
froze the node that sent it. The kernel keeps the lines it signed since
the last resend and those the last resend sent, so a resend signs
nothing new.

### The binary's network

The kernel's network and named files, and the service's socket, are Soma
in the binary too: `node_net.soma`, the binary runner's layer
(`net_op`, which node_shell.soma's `run_net` asks first, as the kernel
asks `host_op`), with its state (`net_state`) handed from one operation
to the next and from one turn to the next. It keeps the node's home, the
listener, the links (a peer's, read as it comes; one the kernel dialed,
with the bytes waiting to go, 64 MiB at most, and whether it is still
connecting), the service's listener and clients with the bytes each
sent past its last whole request, and the jobs' processes. A mailbox is one select over the
listener, peers' links, dialed links with bytes to write or still
connecting, and the processes (whose output wakes it); then a new
connection (one a turn), then each link in turn: a dial's outcome
checked, a dialed link written to as far as it takes, a peer's bytes
read. A failed select is logged with the number of connections and
waits a fifth of a second. The node's named files are paths in its home
(`IoReadText`, `IoSave`, `IoAppendSynced`). The service's requests and
answers are frames of frames, `Soma.Wire`'s `frame` and `take_frame`
(Soma's, which Sandbox exports and the image sends and receives with):
a request is taken whole from a client's bytes, one over 1 GiB drops
the client, and an answer is written out whole (a client's socket
blocks).

What it asks the shell for: a socket by name (`IoSockListen`,
`IoSockDial`, which doesn't wait, `IoSockSelect` of names to read and
to write, `IoSockAccept`, `IoSockRead` of 64 KiB at most, giving bytes,
"again" or "closed", `IoSockWrite`, giving what it wrote, "again" or
"failed", `IoSockError`, a dial's outcome, and `IoSockClose`), a file
written whole or appended (`IoSave`, `IoAppendSynced`) and
`IoNoSigpipe` (a write to a closed connection is an error, not the end
of the process). shell.ml keeps a table of descriptors by name, and
nothing of the node: `node_open` and its handles are gone, and so is
node_io's handle argument (`node_io : list string -> nanswer`). This was shell.ml's largest
part, about 175 lines of links, buffers, the mailbox's select and the
service's framing; there it is now about 90 lines of socket calls.

The jobs' processes are here too, for the binary and for the service
(which runs an image's): `IoProcStart`, `IoProcKill` and `IoEvents`,
which node_host.soma asks for, are `net_op`'s. It keeps each process
(the job's name for it, numbered as they start, the pipe its output
comes on, its pid) and the processes killed. A look (`net_proc_events`)
selects over their pipes without waiting, then takes each in turn: a
killed one ends at once (a check's shell killed, the `yes` it ran may
still hold the pipe open and write), a ready one is read (`job_bytes`)
or, closed, ends; the output comes first, then the ends (`job_ended`,
how and its number: the wait status's facts). A process ends with its
pipe closed and a wait (`IoWaitPid`; one that fails is an exit of -1,
where the shell's exception used to end the node). What it asks the
shell for: `IoSpawn` (the program from its directory, with its
environment and standard input, its output on a pipe named among the
descriptors: its pid and the pipe's name), `IoWaitPid`, `IoKillPid`, and
the descriptors' select, read and close; `IoSockSelect` no longer has a
flag for the processes (the mailbox names their pipes). This was
shell.ml's largest part with logic in it, about 80 lines of the process
table, kills and events; there it is now about 30 lines of spawn and
wait.

The service frames with the functions the image uses, and they are
proved: what is kept never holds a whole frame, and the frames don't
depend on how TCP cut the bytes (Wire.v's `split_frames_kept` and
`receive_frames_chunking`, of what runs: `take_frame_eq`). For that,
Soma gained `Soma.Wire` (Sandbox's lines and frames, which any program
can import without becoming a unikernel; `take_frame` and `split_at` by
offset, proved equal to the character-at-a-time ones), and a program
that extracts `nat` as `int` now gets String's length, get and
substring as OCaml's, as an image does (main.soma no longer says so
itself).

### Git and programs

Git, a clone and a program run to its end are Soma in the binary too:
`node_git.soma`, a layer with no state that both of the binary's runners
ask (node_shell.soma's `shell_answer`, for `run_shell` and for what
`run_net` doesn't carry out itself), whoever asked for the operation:
the commands, the host's work, or an image through its service. `IoGit`
and `IoGitEnv` are git for a checkout Pantheon owns: the extra
environment entries first, then `GIT_CONFIG_NOSYSTEM=1`,
`GIT_CONFIG_GLOBAL=/dev/null` and `GIT_TERMINAL_PROMPT=0`, then the
process's environment without any of git's; `-C` the checkout and `-c`
for no hooks, no signing, no line-ending or mode or symlink guesses.
`IoClone` clones with the user's own config (credentials for a private
repository) but never a prompt, then checks the commit out as above.
`IoRun` runs a program with the user's environment. Each is the
environment read (`IoEnvEntries`) and one `IoExec`: a program run to its
end with exactly the environment it is given and a standard input (none
for ""), giving whether it succeeded and its output. shell.ml's git,
clone and run, about 25 lines of environments and arguments, are gone;
it keeps `capture`, which `IoExec` is.

### Paths

A path in a checkout as an edit, a merge's file work and the service's
guard see it (`IoPathProbe`) is Soma too: `node_path.soma`, asked by
`shell_answer` like node_git.soma. It walks the path's parts below the
directory, each joined to the one before, and asks the host what each
is (`IoPathStat`, an lstat, which doesn't follow the last part): a
symlink anywhere on the way answers "symlink", so a write can't leave
the checkout; a part that isn't there ends it, "none"; otherwise the
last part's kind, "dir" or "file" (anything else that is there counts
as a file). That is what shell.ml's `no_symlink` and `path_probe` did,
which are gone; it keeps `path_stat`, the lstat itself.
node_path.proof proves it of any answers the host's stat gives:
`probe_only_looks` (every operation is a stat of one of the path's
parts, in order), `probe_finds_symlinks` (a symlink on the way, every
part before it there, answers "symlink"), `probe_found_every_part`
("dir" or "file" only when every part is there and none is a symlink),
`probe_none_is_missing` ("none" only when a part isn't there) and
`probe_answers` (one of the four). With node_service.proof's
`symlink_never_followed`, the service runs nothing through a symlink the
host's stat reports at the time it looks.

### Files

How the binary writes its files is Soma: `node_file.soma`, asked by
`shell_answer` like the two above, for the kernel's named files (through
node_net.soma's `IoSave`), the commands, the host's work and the
service. A file written whole (`write_whole`) is its text put in
`FILE.pantheon-tmp` (on disk first when it must be), the file's mode
kept, then renamed over the file, so the file is the old text or the
new, never part of one; durable, the directory is synced after the
rename, so consensus.state's text is on disk before any vote it holds
is sent. Directories are made where none is, the highest first
(`make_dirs`); a path's write in a checkout makes the directories above
it, then writes the file whole; a path's removal and a discarded file
are one removal; a temporary file is a new private one, then written
whole. A tree (a checkout, a temporary directory) is removed in the
background, since a checkout with a build in it is close to a GB and
removing it in the main loop stalled consensus for minutes: `rm -rf --
PATH` started on its own (`remove_tree_prog`), the path one argument
with no shell between, where shell.ml's `remove_tree_later` built a
`/bin/sh` line with the path quoted into it. A save or a temporary file
that fails ends the binary, as the exception did. shell.ml's `write_file`, `mkdir_p`, `path_write`,
`path_remove` and `temp_file`'s write are gone; it keeps one call each:
`file_put` (create or empty, write, sync if asked), `file_mode`,
`rename`, `sync_dir`, `make_dir`, `remove_file`, `temp_new` and
`start_detached` (a program forked twice, so its parent is the system's
and nothing is left to reap, its input and output `/dev/null`).
node_file.proof proves, of any answers those give:
`failed_put_renames_nothing` (the file is as it was),
`whole_write_order` (the put, the mode kept, the rename, then the
directory synced), `whole_write_only_renames_onto_it` (nothing else
touches the file), `make_dirs_only_where_none` (never "", "." or "/",
and only where the host said none is), `path_write_writes_its_file` and
`failed_save_ends` and `remove_tree_starts_rm` (rm started on its own,
the path its one operand after `--`, and nothing else).

## The edits machinery

An edit is a path, the old text and the new (docs/DESIGN.md). What edits
do is Soma's, in `cli.soma`, for all three of their uses:

- **Applying edits** (`edits_prog`): each edit's plan from the shell's
  look at its path (`edit_plan_of`: unsafe, through a symlink, a
  directory, nothing to delete, no such file, or read it and replace the
  one place its old text appears, `edit_apply`), then the write or the
  removal; the first that can't be made stops them, with why. A merge
  runs it on a governed repository's checkout (`InRepo`: the node's
  `IoMerge*` operations), `pantheon apply-edits` and `pantheon check` in a
  directory (`InDir`: `IoPathProbe`, `IoReadText`, `IoPathWrite`,
  `IoPathRemove`). The shell keeps one `path_probe`, `path_write` and
  `path_remove` for both.
- **A bid's tree** (`check_tree_prog`, `pantheon check`): the checkout must
  be at the market's head tree; a shared clone, the edits applied, `git
  add -A -f` and `git write-tree`. Whose a failure is (the bid's: its edits
  don't apply; or this node's: its checkout or git) is decided here.
- **A checkout's changes as edits** (`checkout_edits_prog`, `pantheon
  edits`, for a model with tools): HEAD's commit read from the ref files
  alone (`head_commit_prog`: the checkout's `.git`, a `gitdir:` file, or
  `PANTHEON_GITDIR`; `commondir`; loose refs, then `packed-refs`), a
  snapshot repository in a new temporary directory with an empty config
  and the checkout's objects as alternates, `ls-tree` and `ls-files
  --others --exclude-standard` for the paths, then each path looked at
  (`scan_path_prog`): left out under any `.git`, skipped when unsafe, not a
  regular file, through a symlink, binary or new and empty; otherwise
  hashed into the snapshot (`hash-object -w --no-filters`), and a changed
  file staged there (`update-index --cacheinfo`) and read as one edit per
  hunk of git's diff (`diff_hunks`, `hunk_edits_of`) when replaying them
  gives the new text, else one whole-file write. No git command runs on
  the model's repository, so no config there can run anything.

The shell does the file and git work, with no node: `IoPathStat` (a
path's kind, its last part not followed, and its owner's execute bit),
`IoTempDir`, `IoRemoveTree` (in the background, node_file.soma's) and `IoGitEnv` (git with
the snapshot's environment entries first). `test/edits.sh` checks the
three uses, including the hostile `.git` and `PANTHEON_GITDIR` configs,
and `test/check-*.sh` the check. `pantheon edits` on a 250-file checkout
takes about 2.4 s, most of it one `git hash-object` process a file, as
before.

## The host's work

What a node asks of its checkouts, its model and CI is Soma too, in the
kernel: `node_host.soma`, which `kernel_op` asks first (`host_op`). The
binary and the unikernel run the same code; only the primitives below it
are the runner's (the shell for the binary, the service for an image).

- **A checkout's work**, in HOME/repos/NAME: a merge's reset, its file
  reads, writes and removals (`IoMerge*` become `IoPathProbe`,
  `IoReadText`, `IoPathWrite`, `IoPathRemove`), its commit (`git add -A
  -f`, then `git commit` with a fixed author, a date from the version and
  the message on standard input, then the tree and short id), the files a
  prompt reads (`ls-files`, `show HEAD:PATH`), each checkout's head for
  the status (its genesis commit when git can't read it, as in an image
  with no service), and a `cmd:` patch's tool checkout (a temporary
  worktree, its git directory beside it, a shared clone at the head).
- **What it keeps**: the model's call count, its limit (until when, why,
  the next backoff), whether a release is probing, the requests held for
  it, and the inbox's last poll. In an image these are the image's own
  now, not the service's, so `--max-llm-calls` and the backend are the
  image's flags.
- **Jobs**: a model call, a check or a CI run is a job. The kernel starts
  its process (`IoProcStart`: the program, its arguments, its environment,
  its standard input, a fresh scratch directory to run from) and keeps
  what the shell used to keep in closures: what the job's end becomes
  (`job_done`: a model's `llm_output`, codex's `codex_file`, a check's
  `check_apply_out`, a CI run's `ci_done`), what goes with it (`job_clean`:
  a file, a tree, a container), when it started and its time limit, and
  whether the node stopped it (`IoProcKill`) for its limit or its output.
  The shell gives a job's output as it comes (`job_bytes`) and its end
  (`job_ended`: how it ended); the kernel makes that node.soma's
  `job_finished`, and node.soma's outcome (`IoJobComplete`) queues what the
  end becomes and removes what went with it. CI's one-at-a-time turn and
  its queue are the kernel's, as are a CI run's script (`ci_wrap`) and its
  Docker or sandbox command line.

The shell keeps the primitives: the path operations, `IoTempDir`,
`IoTempFile` and `IoRemoveTree` (node_file.soma's, above, "Files"), `IoExec`
(a program run to its end with the environment it is given: git, a
clone and `IoRun`'s `rm`, `chmod` and `docker rm` are node_git.soma's
over it, above, "Git and programs") and the processes (`IoSpawn`, `IoWaitPid`, `IoKillPid`),
whose table and events are node_net.soma's (above, "The binary's
network").

## The node as a unikernel

node.soma imports no shell. What it called in `shell.ml` as pure
bindings is Soma's: JSON (`util.soma`'s `json_tokens`, the tokens
Yojson.Safe's reader gives, comments, bare keys, NaN and surrogate pairs
included), floats (`float_wire`, `float_text`, `float_of_digits`: `%.17g`,
`%.0f` and `float_of_string`, exact, through SpecFloat), `clean_text`, the
line and job limits, and a transaction's key (the market's table, above).
`test/text-values.sh` runs 610 floats and 248 JSON texts through them
against what OCaml and Yojson give. The binary's interpreter, `run_shell`,
and `run_node` are `node_shell.soma`'s, the one module but main.soma that
imports `shell`.

`pantheon image HOME FILE` runs a node's setup (`node_setup`, as `pantheon
node HOME` does) and writes FILE: a Soma program that requires Sandbox,
with the setup's framed data as a list of strings, whose `main` is
node_sandbox.soma's `run_node_image_at` (the kernel, run with Sandbox). `soma build FILE` (with
`SOMA_MIRAGE_SWITCH` naming Soma's MirageOS switch) makes the image, and
`solo5-vmnet -- solo5-hvt --block:storage=DISK -- IMAGE --ipv4=IP/24
--ipv4-gateway=GW` boots it on the Mac's vmnet network at the address
its genesis gives it: listening on that address's port, the boot program (the snapshot
read back, signed.log restored, genesis and blocks.log replayed), then the
tick, forever, with Sandbox's `iterate` (a loop with a state, which Soma
added for it). Its files (blocks.log, signed.log, status.txt,
consensus.state) are named files on the storage device, so a reboot on
the same disk restarts the node as the binary's restart does: it reads its
votes back and won't sign against them.

Its peer links are the binary's, being the same kernel's. It dials each
genesis peer it has no link to, at most once a second (Sandbox's
`connect_within`, giving up after 300 ms, so a peer that doesn't answer
doesn't hold up the loop), and writes its signed lines there; every 2
seconds it resends what the height recorded and its recent transactions
(`kpoll_prep`). What peers' connections do comes in through Sandbox's
mailbox (`listen_mailbox`, `mailbox`): a connection opened is a
`conn_offer` event, which Soma admits, refuses or makes room for
(`IoConnAdmit`), its bytes `peer_bytes` (held until it is admitted), its
end `peer_closed`. So the same node.soma code splits the lines, checks
their signatures and decides.

`test/node-image.sh` makes a network of four, the image's address on
the vmnet network and the binaries' on the host's side of it, and runs
the image beside two binaries with the fourth down: a block takes 3 of
4 votes, so the chain moving shows the image votes (four heights in
about 7 s), and the image's blocks.log, read from its disk, is the
binaries'. It stops the image (the chain stops), boots it again on the
same disk three times with the fourth agent still down, and checks the
chain moves on each time, signed.log was kept and the image's disk gets
the same blocks as claude's.

Rebooting with exactly a quorum up (the fourth agent down) found three
gaps in the protocol, the binary's as much as the image's, now fixed:

- **Catch-up from one node.** A node stopped after saving a precommit
  and before sending it decides that height from its snapshot when it
  starts again, and moves on alone. Resend memory drops a height once
  it's decided, and a reboot empties it, so that precommit was never
  sent; the others take a block they missed only from f + 1 matching
  `done` messages, which one node ahead can't give. Now a node answering
  a peer one height behind (`behind`, node.soma's `catchup_plan`) also
  sends it, with `IoSignedAt`, every message it signed at that height,
  which completes the peer's quorum. A peer two or more behind needs
  none of it: a quorum decided the next height, so f + 1 honest nodes
  are past this one and send its block.
- **A restart left its round.** A node started again went on to the
  next round. Stopped after its prevote, it left the others, who had
  precommitted in that round, waiting there for its precommit, and one
  node in a later round isn't the f + 1 that moves them (4 of 15 runs).
  Now it stays in its round, with that round's timers back
  (consensus.soma's `resume_timers`), sends what it signed at its height
  again and keeps it in resend memory (node.soma's
  `resume_signed_prog`), and finishes the round with the others.
- **A snapshot ahead of signed.log.** A step's snapshot was saved before
  its votes were signed, so a node stopped between the two started from
  a snapshot saying it had voted, with nothing to send. Now a step's
  votes are signed before its snapshot and sent after it
  (`sign_effects`, in `order_effects` and `startup_effects`).

### The node's service

A unikernel runs no processes and has no checkouts, so what the binary
does with them it asks the node's service for: `pantheon service HOME
HOST:PORT [node flags]` on the host, with `pantheon image HOME FILE
--service HOST:PORT` making the image that uses it. The service is the
node's own runtime (shell.ml's primitives, from HOME's setup, as
`pantheon node HOME` builds them) with a loop of its own, Soma's like the
node's (node_service.soma's `service_tick_prog`, node_shell.soma's
`run_service`): the next request (`IoServeNext`), run as the binary runs
that operation (`run_net`) if the service allows it, its answer sent
back (`IoServeReply`).

What goes to the service is one set, nodeio.soma's `service_op`: the
host's primitives the kernel's host work runs on ("The host's work"
above): git and paths in the checkouts, temporary files and
directories, programs run to their end, processes started and killed,
the model's reply files and the inbox on the host's disk, and the events
the processes give. What those are for (a merge, a model call, a check,
CI's turn) is decided in the image's kernel, which keeps the jobs, the
model's budget and limit and the held requests itself. Everything else
is the image's own: its votes, blocks, peers, tables and status. The kernel hands a `service_op` operation on as it
is, and the image's runner (node_sandbox.soma's `iop`) sends its wire
form (`io_wire`) to the service and hands its answer back; each select
turn (`IoEvents`) also asks for the host's events, which are the events
the service's jobs gave, after the mailbox's, waiting a fifth of a second at most when it has a service, as
a job's output doesn't wake the mailbox. The service keeps those events
until the image takes them, as many as fit in one answer, and leaves
out its own listener's (which no peer dials: the image is the node on
the network).

On the wire, over one TCP connection the image opens (Sandbox's
`connect_within`, `send_frame`, `receive_frame`): a request is a frame
(Sandbox's `frame`: four bytes of length, then the bytes) of frames, one
a field: the token, then the operation's wire form; an answer is one
too: found, the float as `%.17g` text, then the data. The token is the
node's, a hash of its private key (`service_token`), which the image and
the service each have; the service answers `service_op` operations with
it and refuses anything else (node.proof's `service_answers_only_its_own`).
A connection that fails is opened again for the next request; with no
service, or none reachable, those operations answer that they aren't
there, as before, and the image votes and keeps the chain but can't
merge, bid or check.

The service carries out only what the node's own host work asks
(node_service.soma's `sv_allowed`), judged from what it knows itself:
its setup (HOME, the backend, CI's memory, image and sandbox runner),
its own binary and environment (`IoSelfExe`, `IoEnvEntries`, read once),
and the temporary files and directories it made (newest first, a
removed one taken out). So a token alone isn't the host:

- **Paths** (stat, read, list, write, remove, probe) are under
  HOME/repos, HOME/inbox, or a temporary path the service made (or its
  `.git` beside it), absolute, with no `..` part; never HOME itself,
  where the node's key is. Before a read, write, listing or removal the
  service probes every part below the root (`IoPathProbe`) and refuses
  one through a symlink.
- **Git** is one of the host work's fixed calls (the heads, a tree,
  adding everything, the tracked files, putting a checkout back), a
  commit checked out, a file at the head, a merge's commit (its
  author, committer and date entries, nothing else in the environment)
  or a `cmd:` patch's clone between paths it may use; no argument of its
  own is an option, so no `-c`, `--config`, `--upload-pack`, `--exec`.
- **Processes** are the node's own binary checking a bid, the model as
  `backend_launch` launches it (codex's reply file and grok's header
  file ones it made), CI exactly as `hci_start` makes it (in docker
  with the service's memory and image over a tree it made, or its
  sandbox runner), or its own `cmd:` backend with no arguments; from a
  directory it may use, with its own environment's entries and a `cmd:`
  patch's four. **Programs run to their end** are `rm -rf` and
  `chmod -R a+rX` of a path it may use and `docker rm -f` of a CI
  container.
- **The rest**: temporary names with no directory in them, random hex of
  at most 99 digits, killing its own jobs. Any other operation is
  refused.

A refused request runs nothing, is answered not found with the reason,
and is said in the service's log (`service refused OP: why`).
node_service.proof proves it of these functions, both ways. What it
refuses: `refused_runs_nothing`, `allowed_are_host_ops`,
`only_the_token_is_served`, `paths_stay_in_roots`,
`roots_are_the_services`, `path_operations_are_looked_at`,
`symlink_never_followed`, `processes_are_the_nodes_own`,
`runs_are_cleanup`, `git_takes_no_options_of_its_own`, and examples on
one service's world (the key, `..`, a sibling of a root, an alias, an
upload pack, `GIT_SSH_COMMAND`, `LD_PRELOAD`, another image, the clock).
And that it takes nothing the node needs: what node_host.soma and
node.soma ask is served (`checkout_git_is_served`,
`merge_commit_is_served`, `tool_checkout_is_served`,
`model_launches_are_served`, `check_job_is_served`, `ci_is_served`,
`cmd_backend_is_served`, `service_environment_is_served`,
`cleanup_is_served`, `temporary_names_are_served`). The service has to
be started with the image's `--backend` and CI flags, as the node's
host work asks for those.

What it still allows: the token's holder reads the service's
environment (`IoEnvEntries`, which the model's and git's environments
are made from); the model, a check and CI run as the node's would, with
what they can reach; a process the service started could put a symlink
in a path between the probe and the operation (the service itself is
one request at a time); and the token crosses vmnet in the clear.

`test/node-image-service.sh` runs the image with its service beside three
binaries, all four up, with a fake model (a `cmd:` backend): the market
merges work in about 11 s, the image's bids and attests are in the blocks
(its attests carry the tree its checks computed, jobs on the service),
muse's model ran on the service (its copy of the model logs each call),
the image led a term (picked bids, proposed a merge), and the service's
checkout is at the binaries' commit.

Limits, for now: a frame is 1 MiB at most (Sandbox's `max_frame`), so a
model reply file or one job event over that is lost to the image (the
model's output is capped at 4 MiB); the token crosses the host-only
vmnet network in the clear, so the service listens on the host's side of
that network only. (The model's budget and limit were the service's
flags until the host's work moved into the kernel; they are the image's
now.)

What the image doesn't do yet:

- **Storage.** Sandbox's named files are rewritten whole on every write
  (two banks, a 16 MiB cap on all of them), so blocks.log can't grow far.
  An append that writes only its bytes is Soma's item.
- **Time.** Its clock is the monotonic one, from boot.

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

- U-1, peer links and job control: admitting, refusing or evicting an
  offered connection (`IoConnAdmit`), closing one (`IoConnClose`), and
  killing a job over its output cap (`IoJobFlood`) or past its limit
  (`IoJobExpire`) are node operations interpreted by shell.ml's `node_io`;
  the `node_conn_admit`, `node_conn_close`, `node_job_flood` and
  `node_job_expire` bindings are gone. `expire_ops` gives the deadline
  pass's exact operations. Sandbox has `listen`, `connect` and `close` for
  links but no admission hold or eviction, and no processes, so it lacks
  the job kills. `test/link-job-ops.sh` runs the operations through a pure
  scripted interpreter.

- Step 5, the line cap and admission's plan: the buffered-line byte cap
  is Soma's `peer_line_cap` (60 quoted transactions at `tx_byte_cap`,
  the old `max_line`); the `node_line_limit` binding and the shell's
  `max_line`, `max_conns` and `max_conns_per_host` are gone.
  `peer_read_events` turns one read into the kept chunks, its lines'
  `peer_raw` events and the close verdict, and `conn_admit_plan` names
  the mode and the evicted connection, which the `peer_bytes` and
  `conn_offer` cases carry out. `test/peer-read.sh` checks 30 exact
  results: split and multiple lines, empty reads and EOF, both cap
  edges, admission at and past both caps with the evicted connection,
  and each line kind's event. The shell keeps select, reads, accepts,
  closes, the held-request and limit storage, and the job launch's
  output-file plumbing; the plan stays open.

- Step 5, check eligibility: `check_request_op` selects a check launch or
  the queued unchecked-repository fact from raw flag and scope lists.
  Scope exclusions retain precedence over `--no-check`. The native gate
  is gone; refused checks no longer create temporary files just to delete
  them. `test/check-eligibility.sh` checks six exact operation results.
  Other native orchestration still needs auditing; the plan stays open.

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
  only reads the JSON's members (`tx_parts`); the signature is checked by
  Soma since (`nio_tx_verify`, with `tx_key`'s key). Left of step 5: the limits on lines and connections.

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
  removes, commits and records. (Since then `check` and `apply-edits`
  apply edits with the same program: see "The edits machinery".)

- The helper callbacks (step 3) were one typed `shell_helpers` record in
  `util.soma`. `node_open` receives it once; the binding transports its three
  remaining fields as a product (`pack_helpers`), since `.definition`
  accepts products but not Soma record types. `shell.ml` unpacks it into a
  named OCaml record and threads it through edit and command callers.
  `edit_once` serves edit application/diff replay, `contains` serves URL
  resolution and CI error classification, and `shell_safe_path` serves path
  checks. `util.proof` checked all three packed callbacks on pure inputs.
  With the edits machinery in Soma, no OCaml calls them: the record and
  `cli_open` are gone, and `node_open` takes only the setup.
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

Held-request orchestration is now Soma too: `held_batch_of` selects the
oldest probe, preserves the newest-first remainder, drains a successful
limit's queue oldest first, and updates the probe flag. The shell exposes
only queue/probe storage. Event construction continues through the merged
`held_request_event`; empty release batches produce no event. New fixed
checks cover exact fields, ordering, empty queues and 5000 requests, with
proofs for the none/all plans and a concrete oldest-first Example.

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

Step 5's job wait-status boundary now reports raw signal integers for
`WSIGNALED`/`WSTOPPED`. `node_job_signal_codes` exposes the five native constants;
Soma's `job_signal_name` maps those to names, preserves unknown signed values,
and `job_wait_status` keeps exit codes separate. The job-output path calls this
before formatting the existing timeout/flood result. Four general proofs and
16 fixed checks cover the mapping and its use, including the actual platform
constants. The shell's signal-name decision branches are removed.
