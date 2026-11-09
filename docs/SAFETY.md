# Safety

What can go wrong when four agents change real repositories, and what stops
it. The assumption throughout: at most one of the four agents is faulty. That
covers a compromised model, a malicious node, or one that's simply broken.

## Nothing merges without an honest check

- A merge needs 3 of 4 approvals: the leader, who proposes, plus attestors.
  The bidder's approval counts too after `fallback_blocks`, so one silent
  attestor can't block everything. Even then, at least one attestor must vote
  yes. `market.proof` proves both rules.
- An attestor's node applies the bid's edits to the head in a fresh clone,
  computes the resulting tree, and runs CI if it has one. Only then does it
  ask its model. A yes names that tree.
- The leader's merge transaction names the tree its own check produced, and
  a yes counts only when it names the same tree. Every merge therefore has the
  leader and at least one attestor agreeing on the tree. With at most one
  faulty agent, an honest node computed it.
- After the merge, every node applies the same edits to its own checkout and
  checks it reaches that tree. If it doesn't, the node says `DIVERGED` loudly,
  in its log and its status, and stops taking merges for that repository.
  `test/e2e.sh bad-tree` runs a node that lies about trees: its votes never
  count, and no checkout diverges. With an earlier rule, where the first yes
  chose the tree, the same test made checkouts diverge. That's why the rule is
  this one.

## Edits can't escape the checkout

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

Git runs with no user or system config, no hooks, and no signing, so every
node does exactly the same thing, and a repository can't run code on a node.

## Models are kept away from keys

- The node's home holds `key.json`. It's made `0700`: nobody else on the
  machine reads it.
- Built-in backends (`claude`, `codex`, `grok`) run with every tool off, from
  an empty scratch directory, and get no `PANTHEON_*` settings.
- A model with tools (`scripts/bidder-*.sh`) gets a scratch checkout outside
  the home. Claude Code may read and edit only inside it, and may run only
  `soma`, the tests, `git diff`/`status` and `ls`. codex runs in its
  workspace-write sandbox. Both can still read what the node's user can read.
  For a real network, run the model as another user: set `BIDDER_USER` (with
  passwordless sudo to that user, and that user's own model login), and the
  home's `0700` keeps the keys out of reach.
- Text from other agents and from repositories is fenced in prompts with a
  fresh random token. Soma defangs `{{` in anything quoted, so quoted text
  can't forge a fence or pull in other files.

## CI can't reach anything

Attestors run CI in a container with no network, a read-only root, no
capabilities, no new privileges, nobody's uid, and limits on processes and
memory. The checkout is mounted read-only. A CI command copies it to `/tmp`
to build.

## What reaches GitHub

`scripts/mirror.sh` pushes only what the market merged, to each repository's
default branch: by fast-forward, or by a merge commit (made by the mirror,
naming the market's head) when people committed there too. It never
force-pushes the default branch; a conflict goes to `pantheon/unmerged`
instead. So what reaches the default branch passed 3 of 4 approvals and the
attestors' CI, run on their own machines, not GitHub Actions. If you want a
person to review every merge as well, point the mirror at a side branch and
protect the default branch (docs/NETWORK.md).

## Keys and votes survive restarts

`signed.log` remembers every vote signed, so a restarted node can't sign a
second, different vote for the same slot. Keep it with the keys (see
docs/NETWORK.md, "Replacing a machine").

## Known limits

- **Two faulty agents** can merge anything: that's beyond f = 1, by design.
- **The draw** can be steered once by an agent that holds back its link, at
  the cost of its own next chance (docs/DESIGN.md).
- **No membership changes**: replacing an agent's keys means a new genesis.
- **Prompt injection** through repository content is fenced, not prevented:
  a model may still be fooled. That's why every merge needs an honest node's
  check and CI, and not only a model's yes.
- **CI is only as strong as the command.** Without CI, attestors check that the
  edits apply, not that they build.
- **A check blocks briefly.** Making a scratch checkout for a bidder with tools
  happens in the node's loop. For a repository the size of Soma that's about
  a second.
