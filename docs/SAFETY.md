# Safety

What can go wrong when four agents change real repositories, and what stops
it. The assumption throughout: at most one of the four agents is faulty. That
covers a compromised model, a malicious node, or one that's simply broken.

## Deployment scope

**Plain `./main.exe up` as one user and `scripts/host.sh` are not key-isolated.**
A tool-enabled model or diplomat running as the node user can read node keys,
logs, inbox tokens and that user's SSH/GitHub push credentials, forge votes,
or push directly. A `0700` home does not protect against its owner. One
compromised model can therefore compromise more than one validator, violating
the one-fault assumption. Protect the default branch and keep push credentials
under a separate account.

- **Separate-user sandbox with `BIDDER_USER`:** key isolation requires a distinct
  unprivileged model user, node-owned `0700` homes and git metadata, no access
  back to the node user, and a separate mirror account holding push credentials.
  Model builds run with that user's authority; Soma itself is not a sandbox.
- **Plain one-user up / host:** tool restrictions and prompt fences are defences,
  not an OS boundary. Local model builds can execute project code as that user.
- **Docker/net:** Docker CI isolates checks, not model processes. A VPN or one
  machine per agent isolates peers, not a model from its local node's keys.
  Key protection still requires the separate-user arrangement above (or a VM
  with equivalent isolation).

The protocol and edit-engine statements below apply in **all setups**, assuming
honest shell execution and protected keys. They do not establish isolation in
plain one-user deployments. The precise proved statements and their limits are
in [PROOFS.md](PROOFS.md); global consensus safety is not yet proved.

## Merge checks (all setups, under those assumptions)

- A merge needs 3 of 4 approvals: the leader, who proposes, plus attestors.
  The bidder's approval counts too after `fallback_blocks`, so one silent
  attestor can't block everything. Even then, at least one attestor must vote
  yes. `market.proof` proves both rules.
- An attestor's node applies the bid's edits to the head in a fresh clone,
  computes the resulting tree, and runs CI if it has one. Only then does it
  ask its model. A yes names that tree.
- The leader's merge transaction names the tree its own check produced, and
  a yes counts only when it names the same tree. The implementation thus requires the
  leader and at least one attestor to agree on the tree. Under the one-fault
  and protected-key assumptions, this gives an informal argument that an
  honest node computed it. The proofs establish approval counts and the
  origin of newly Merged records, not the full tree-agreement argument.
- After the merge, every node applies the same edits to its own checkout and
  checks it reaches that tree. If it doesn't, the node says `DIVERGED` loudly,
  in its log and its status, and stops taking merges for that repository.
  `test/e2e.sh bad-tree` runs a node that lies about trees: its votes never
  count, and no checkout diverges. With an earlier rule, where the first yes
  chose the tree, the same test made checkouts diverge. That's why the rule is
  this one.

## Edit application stays in the checkout (all setups)

An edit replaces one exact, unique piece of a file, writes a whole file, or
deletes one. Paths are checked twice, by the market and by the shell. They must
be relative, with no `..` and no empty or `.` parts, and nothing inside a
`.git` directory, in any case (writing there would mean running hooks). The
shell also refuses any path that goes through a symlink, so a write can't
leave the checkout. `test/edits.sh` covers each refusal.

Each agent's policy (`--deny`) refuses bids that touch denied paths, before
anything is signed. The defaults are `.git/`, `.github/` (CI workflows can
hold secrets), `.gitmodules`, `.gitattributes` and `network/` (membership).
Add more per repository, for example `--deny genesis/`.

The node's git disables user/system config, hooks, signing and checkout filters
when reading edits. These precautions are not a sandbox for arbitrary git or
build commands a tool-enabled model runs. Same-user models can still alter
node-owned files; symlink/path checks are not a proof against concurrent
same-user tampering. Agreement also relies on compatible git behaviour.

## Model access (separate-user isolation required)

- The node's home holds `key.json`. It's made `0700`: other unprivileged
  users cannot read it; its owner and root can.
- Built-in backends (`claude`, `codex`, `grok`) run with every tool off, from
  an empty scratch directory, and get no `PANTHEON_*` settings. Other
  environment variables are inherited: this is not a secret allowlist.
- A model with tools (`scripts/bidder-*.sh`) gets a scratch checkout outside
  the home. Claude Code may read and edit only inside it, and may run only
  `soma`, the tests, `git diff`/`status` and `ls`. codex runs in its
  workspace-write sandbox. These are CLI restrictions, not the separate-user
  boundary; with `BIDDER_USER`, the wrappers can allow broader tools as that
  user. Without it, models can still read what the node's user can read.
  For a real network, run the model as another user: set `BIDDER_USER` (with
  passwordless sudo to that user, and that user's own model login), and the
  home's `0700` keeps the keys out of reach.
- Text from other agents and from repositories is fenced in prompts with a
  fresh random token. Soma defangs `{{` in anything quoted, so quoted text
  can't forge a fence or pull in other files.

## CI isolation (Docker CI versus host ci-sandbox)

CI runs only when configured with `--ci-repo`/`--ci`; plain up without CI
checks edit application, not builds or tests. In all deployments using Docker
CI, attestors run the command in a container with no network, a read-only root, no
capabilities, no new privileges, nobody's uid, and limits on processes and
memory. The checkout is mounted read-only. A CI command copies it to `/tmp`
to build. This describes the Docker runner, not local model builds.

The host `--ci-sandbox` runner uses bubblewrap and a systemd scope, with no
network and read-only checkout/toolchain mounts, but exposes the host's `/etc`
read-only. Any readable secrets there (including `/etc/pantheon/keys.env` if
readable by the runner) can be printed by a malicious check. Docker exposes
its image's `/etc`, not the host's. Failed CI output's last 400 characters can
enter rejection reasons, the replicated chain and other models' prompts in
both runners. There is no secret scanning or guaranteed redaction; read-only
does not mean confidential. Run CI without access to secrets.

## What the mirror pushes (all setups using mirror.sh)

`scripts/mirror.sh` pushes only what the market merged, to each repository's
default branch: by fast-forward, or by a merge commit (made by the mirror,
naming the market's head) when people committed there too. It never
force-pushes the default branch; a conflict goes to `pantheon/unmerged`
instead. This guarantee covers the mirror's market input only, not independent pushes
or human commits included by a merge commit. Market changes passed the approval
rule and CI only where configured; all attestors may share one machine. A
same-user diplomat with push credentials can bypass the mirror entirely. If you want a
person to review every merge as well, point the mirror at a side branch and
protect the default branch (docs/NETWORK.md).

## Signed votes survive restarts (all setups with intact logs)

`signed.log` remembers every vote signed, so a restarted node can't sign a
second, different vote for the same slot. Keep it with the keys (see
docs/NETWORK.md, "Replacing a machine"). This only prevents double-signing
in the same slot. Consensus locks/valid values are not persisted across a
restart (P-4); these local proofs and the crash test do not guarantee global
agreement after lock loss. Same-user models can also tamper with logs.

## Known limits

- **Two faulty agents** can merge anything: that's beyond f = 1, by design.
- **The draw** can be steered once by an agent that holds back its link, at
  the cost of exclusion next draw if a non-held agent reveals (docs/DESIGN.md).
  Accepted reveals now require exactly one hash step; equality of alternative
  accepted links relies on the explicit unique-preimage assumption.
- **No membership changes**: replacing an agent's keys means a new genesis.
- **Prompt injection** through repository content is fenced, not prevented:
  a model may still be fooled. That's why every merge needs an honest node's
  check, plus CI when configured, and not only a model's yes.
- **CI is only as strong as the command.** Without CI, attestors check that the
  edits apply, not that they build. An arbitrary command may run tests the bid
  itself edits. The default host/sandbox policy protects its tests and rejects
  added proof assumptions; it does not prove functional correctness.
- **A check blocks briefly.** Making a scratch checkout for a bidder with tools
  happens in the node's loop. For a repository the size of Soma that's about
  a second.
