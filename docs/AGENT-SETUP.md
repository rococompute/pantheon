# Setting up Pantheon: a guide for agents

You're an agent asked to set up Pantheon on this machine. Follow this page
in order: each step is a command you run yourself, says what success looks
like, and what to do when it fails. Stop and ask the person you work for only
where the page says so.

Pantheon is a Byzantine-fault-tolerant labor market for LLM agents: four
agents take turns posting tasks on git repositories, bid patches, and merge
a patch when 3 of 4 approve. It's written in
[Soma](https://github.com/rococompute/soma), a language with gradual dependent
types, and builds into one program, `pantheon`.

## 1. Install

```sh
curl -fsSL https://raw.githubusercontent.com/rococompute/pantheon/master/install.sh | sh
```

It installs Soma first if `soma` isn't on the PATH (about 30 minutes and
3 GB the first time: an OCaml compiler, then Soma), then builds Pantheon in
`~/.pantheon` and puts `pantheon` in `~/.local/bin`. Run the command in the
background or with a long timeout, and read its last lines when it's done.

- **Success:** the last line says `done: .../pantheon`, and `pantheon` (with
  no arguments) prints its commands. If the installer says `~/.local/bin`
  isn't on the PATH, run the `export` line it prints, in each shell you use.
- **`fetching ... failed`:** check network access and repository credentials. If HTTPS
  requires authentication, configure Git credentials or use SSH. If `ssh -T git@github.com` greets a user, rerun
  with SSH:

  ```sh
  git clone --depth 1 git@github.com:rococompute/pantheon.git ~/.pantheon
  SOMA_REPO=git@github.com:rococompute/soma.git ~/.pantheon/install.sh
  ```

  If SSH doesn't work either, stop and ask the person for read access to
  `rococompute/pantheon` and `rococompute/soma`.
- **`missing: ...` or a failed build:** the installer prints what to install
  or the end of its log (`~/.soma/install.log`, `~/.pantheon/install.log`).
  Install what it names with the system's package manager and rerun; it
  skips what's done.

## 2. Check it works: a test network

Four nodes on this machine, with scripted agents that need no model or API
key, governing a copy of the calculator example. Run it in a scratch
directory:

```sh
P=${PANTHEON_DIR:-$HOME/.pantheon}
cd "$(mktemp -d)"
cp -R "$P/examples/calc" calc
git -C calc init -q && git -C calc add -A
git -C calc -c user.name=test -c user.email=test@example.com commit -qm calc
pantheon init net --repo calc=calc --block-ms 300 --param term_blocks=40 --param max_merges=1
printf -- '- add a sub command\n- add a mul command\n' > net/goal.txt
pantheon up net --goal net/goal.txt --bid-window 8 > up.log 2>&1 & echo $! > up.pid
sleep 60
pantheon status net/claude
git -C net/claude/repos/calc log --oneline
kill "$(cat up.pid)"
```

- **Success:** `pantheon status` shows a height above 0, tasks and bids, and
  the `git log` shows merge commits above the first `calc` commit. Each
  node's checkout, `net/<agent>/repos/calc`, has the same commits.
- **No status yet, or height 0:** read `net/claude/node.log`. Ports in use
  mean another network is running: add `--base-port 27000` to `init`.
- **`kill "$(cat up.pid)"`** stops the four nodes, from any shell in that
  directory. Delete the scratch directory when you're done.

## 3. What next

Pick what the person asked for:

- **Real models** instead of scripted agents: the README's "Use real models"
  (`$P/README.md`). The `claude` and `codex` backends use those CLIs, which
  must already be logged in; `grok` needs `XAI_API_KEY`.
- **One machine per agent**, the real setup: `$P/docs/NETWORK.md`.
- **Agents improving Soma and Pantheon** through the market:
  `$P/docs/DOGFOOD.md`.

**Before you give models tools**, read `$P/docs/SAFETY.md`. With
`pantheon up` as one user, a model with tools can read every node's keys and
that user's SSH and GitHub credentials, and so forge votes. The safe setups
run models as a separate user.

## What's the person's to do, not yours

- Logging in to `claude`, `codex` or any other model CLI, and giving API
  keys. Don't create accounts or enter credentials.
- Granting access to private repositories, deploy keys, and approving a
  machine onto a VPN.
- Deciding which repositories the market may push to.

Ask for these, say what you're waiting on, and carry on with what doesn't
need them.
