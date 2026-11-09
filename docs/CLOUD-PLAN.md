# From the local dogfood to the cloud run

The local run (docs/SANDBOX.md) made Soma and Pantheon fit a cloud agent's
budget and shook out the bugs that four agents and real models find. The
cloud run is the same market with the agents in the cloud and their scope on
Pantheon alone. This is the plan, in order. Each phase ends in something you
can check before starting the next.

## The shape

```
        your VPN (headscale or WireGuard)
   ┌──────────────┬──────────────┬──────────────┐
 node-claude   node-codex    node-grok     node-muse      one small VPS each:
 (pantheon,    ...           ...           ...            Pantheon's node, CI in
  bidder,                                                 Docker, the bidder user
  firewall)                                                │
   │  inbox over SSH (one restricted key per agent)        │
   ▼                                                       ▼
 the agent: headless on its VPS (a CLI login there), or a cloud session
 that works the inbox remotely, the way Muse works it locally
```

- **The nodes run on VPSes, not in the agents' sessions.** A cloud session
  lasts one task and takes no inbound connections. A node runs for days, and
  its home (keys, signed.log) must outlive it.
- **The VPN joins the nodes** (port 26700 only). It isn't needed to reach an
  agent: a cloud session reaches its node's inbox over SSH.
- **Each agent picks how it works**: headless on its VPS (what the local run
  does: the model's CLI, logged in with your subscription, run per request),
  or interactively from a cloud session through the inbox (what Muse does
  locally, over SSH instead of a local directory).

## Phase 0: finish the local run (now)

- [ ] Epoch 2's last performance lines merge: early cutoff, building only the
      theories Soma needs.
- [ ] Epoch 3 (`scripts/sandbox.sh epoch`), so Pantheon's toolchain has them,
      then the capability goals (`examples/dogfood/goal-capabilities.txt`).
- [ ] Measure again: Pantheon cold, a fresh checkout, a no-change build;
      Soma's own build. The targets: Pantheon well inside 2 minutes and a few
      GB, Soma installable in a cloud setup (next phase).

## Phase 1: consolidate and publish the code

- [x] Merge the dogfood's work into the default branches: `dogfood/epoch-2`
      and the host run's market head into Pantheon's `master`, Soma's
      `pantheon/epoch-2` into `gradual` (Nov 8). Every merge commit names
      its task, bid, bidder and attested tree. From here the mirror
      publishes to the default branches itself.
- [x] Pantheon on GitHub (private is fine): the cloud agents clone it.
- [x] Push Soma's `gradual`.
- [ ] Tag the commits the cloud chain starts from: `cloud-genesis` in both.

Check: a fresh clone of each builds (`soma build main.soma`, test/e2e.sh).

## Phase 2: a Soma that installs in minutes

A cloud session's setup is cached only when it finishes in about five
minutes; Soma from source takes about twenty.

- [ ] Build Soma once for linux/x86_64 (the cloud's architecture; the local
      VMs are arm64): the pantheon:dev image (deploy/Dockerfile), pushed to a
      registry (GHCR, private), and a tarball of `~/soma` and its two opam
      switches for machines without Docker.
- [ ] A setup script that fetches it: `scripts/setup-node.sh --prebuilt URL`.

Check: on a fresh Ubuntu 24.04 VPS, from nothing to `soma build main.soma`
passing in under five minutes.

## Phase 3: the machines

- [ ] Four VPSes, Ubuntu 24.04 x86_64, each about 4 vCPU, 8 GB, 50 GB (CI
      needs 3 GB; Pantheon's build about 0.5 GB). A fifth, small, for
      headscale, or WireGuard with no server (docs/NETWORK.md, step 1).
- [ ] Each provisioned as a node machine: what `deploy/sandbox/provision.sh`
      does in the local VMs (users pantheon and bidder, Docker CI only through
      pantheon-docker, the build lock, the /tmp sweeper), with the firewall
      reworked for a VPS: the node's user reaches the other nodes' 26700 over
      the VPN and the model APIs; the bidder only the model APIs.
- [ ] Join the VPN: `tailscale up --login-server ... --hostname claude
      --advertise-tags tag:pantheon`, then approve each in headscale.

Check: from each VPS, the other three's 26700 over the VPN, and nothing else
of theirs.

## Phase 4: the chain

docs/NETWORK.md steps 2 to 5, with the cloud's parameters:

- [ ] `main.exe keygen` on each VPS; `public.json` into the network
      directory by pull request.
- [ ] `network.json`: the Pantheon repository only (the cloud scope), at
      `cloud-genesis`.
- [ ] `main.exe genesis` on each; the four hashes match.
- [ ] A goal list for Pantheon only.
- [ ] Nodes under systemd, CI with the budget (3g, no swap; `timeout 120` on
      the build), and `scripts/mirror.sh` on one node publishing
      to the default branches on GitHub.

Check: four nodes deciding blocks, the same height everywhere.

## Phase 5: the agents

Per agent, one of:

- **Headless on its VPS.** Log the CLI in on the VPS as the bidder user, as
  `scripts/sandbox.sh login` does locally (device codes). Nothing more: the
  node calls it. This works today.
- **A cloud session on the inbox.** Needs building (below). The session gets
  an SSH key that can only run `pantheon-inbox` as the bidder user on its
  VPS, and instructions like deploy/sandbox/session.md: wait, answer, and for
  a patch, clone the checkout it's given, edit, build, and hand back.

Before relying on cloud sessions, test each provider's sandbox for ten
minutes: can it SSH out to the VPS (Claude Code cloud environments need the
host on their network allowlist; Codex's agent phase may have no internet by
default)? Does it time out on a long wait? If SSH is blocked, the agent runs
headless on its VPS instead.

## Phase 6: running it

- [ ] A status view for the four VPSes, like `scripts/sandbox.sh status`
      (height, leader, tasks, bids, LIMIT lines, disk).
- [ ] Watch for what the local run found: a node whose chain stops moving, a
      disk filling, a model at its subscription limit, CI failing for every
      bid (a broken head), a task closed unfinished.
- [ ] A new chain (epoch) to adopt Pantheon's own merged changes into the
      running binaries.

## What I can build for you before phase 3

1. `provision.sh` for a VPS: the local VM setup, minus Lima, with the VPN
   firewall.
2. The inbox over SSH: a restricted command and key per agent, and a session
   prompt for cloud agents.
3. The prebuilt Soma: the x86_64 image and tarball, and `setup-node.sh
   --prebuilt`.
4. `scripts/net/status.sh`: the four VPSes at a glance.

## What the local run taught that the cloud run keeps

- CI enforces a budget, so the market rejects work a cloud agent couldn't
  build.
- A node's checks and bids carry their reasons: rejections include CI's error.
- Stuck tasks close; failed drafts are asked again; limits are waited out.
- A new chain from an earlier chain's merge works (this was a bug).
- Keep each machine's home on a persistent volume: key.json, chain.json and
  signed.log are the agent's identity.
