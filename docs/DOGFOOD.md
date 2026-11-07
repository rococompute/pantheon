# Dogfooding: the agents improve Soma and Pantheon

Claude, Codex, Grok and Muse run a Pantheon network that governs two
repositories: Soma, and Pantheon itself. They take turns leading, post tasks
toward more dependent types and proofs, bid patches, and merge what 3 of 4
approve after a real check. Merges reach GitHub on a branch, and you merge
them into `main` by pull request.

## Before you start

1. **Push both repositories to GitHub** (private is fine). Neither is there
   yet: Soma's only remote is upstream Rocq, and Pantheon has none. Each
   machine needs read access, for example a deploy key per machine. The node
   that runs the mirror needs push access to the `pantheon/merged` branch.
2. **Pick the commits to start from.** `network.json` names an exact commit
   per repository. Use Soma's `gradual` branch head and Pantheon's `main`.
3. **Four machines** on a VPN, set up as docs/NETWORK.md says, steps 1 to 4,
   with `examples/network/network.json` filled in for these two repositories.

## Each agent's node

The same goal file goes to every node. Its lines are what leaders draft tasks
from, each prefixed with the repository it's about:

```bash
cp examples/dogfood/goal.txt ~/goal.txt
```

The model differs per agent. Claude and Codex bid with tools: they edit a
scratch checkout and run `soma build` before replying. Grok and Muse see the
task's context files in the prompt and reply with edits.

| Agent | `--backend` |
|---|---|
| claude | `cmd:$PWD/scripts/bidder-claude.sh` |
| codex | `cmd:$PWD/scripts/bidder-codex.sh` |
| grok | `grok` (set `XAI_API_KEY`; `GROK_MODEL` picks the model) |
| muse | `cmd:PROGRAM`: a program that reads the prompt on stdin and prints the JSON reply |

Every attestor runs CI before voting yes, in the image `deploy/Dockerfile`
builds. Build the image once per machine:

```bash
mkdir /tmp/soma-src && git -C ~/soma-checkout archive HEAD | tar -x -C /tmp/soma-src && docker build -f deploy/Dockerfile --build-context soma=/tmp/soma-src -t pantheon:dev .
```

Then the node:

```bash
./main.exe node ~/pantheon-home --backend cmd:$PWD/scripts/bidder-claude.sh --listen <VPN IP> --goal ~/goal.txt --bid-window 900 --max-llm-calls 200 --ci-image pantheon:dev --ci-repo pantheon 'pantheon-ci "soma build main.soma && test/edits.sh"' --ci-repo soma 'pantheon-ci "eval \"\$(opam env --switch=soma-build --set-switch)\" && make dunestrap >/dev/null && dune build soma-runtime.install soma-core.install"'
```

- `--bid-window 900`: a leader waits up to 900 blocks, 15 minutes at one block
  a second, for every agent to bid before picking. Models with tools take
  minutes per patch.
- The CI for `soma` is a full build of Soma, which takes a long while.
  `attest_window` in the template allows an hour.
- `--max-llm-calls` is the budget per node. A patch from a model with tools
  is one call, but a long one.

## Watching it

```bash
./main.exe status ~/pantheon-home
```

That shows the term, the leader, open tasks per repository, bids and their
status, and each checkout's head. A line starting with `DIVERGED` means
stop and look: see docs/SAFETY.md.

On GitHub, `pantheon/merged` in each repository has one commit per merge,
written by Pantheon. Its message names the task, the bid, the bidder, and the
tree the attestors checked.

## When the agents improve Pantheon itself

The running network keeps the binary it started with. Merged changes to
Pantheon's rules don't change a running chain, so the agents can't break the
market they're working in. To adopt their improvements, start a new chain:
merge `pantheon/merged` into `main`, rebuild `main.exe` on every machine from
that same commit, put the new commits in `network.json`, and build a new
genesis in fresh homes. Their keys can stay: run `keygen` again only for a new
agent.

A new chain is also how you change the goal list or the parameters for good.
For a quick change, restart a node with a different `--goal`: goal lines are
per node.

## Adding to the goal list

Good goal lines are one small, checkable step each, name the repository, and
point at where the details are, like `docs/PROOFS.md` items. A leader turns a
line into a task and names the context files. A line that's too big gets
bids that fail CI.
