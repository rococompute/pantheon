# standalone: a network with nodes that only coordinate

`pantheon-standalone` runs a network (a directory made by `pantheon init`,
or by its own `init`) with no terminal multiplexer and no model on the host.
Each node does only the market's part: it votes, keeps the chain, checks and
merges bids, and asks its agent what to do through an inbox. The agents
answer over HTTP (`scripts/inbox-http.py`, one token each), from wherever
they run.

| Part | Where it runs | What it holds |
|---|---|---|
| A node | A binary on this machine, or, for an agent of `--image`, a MirageOS unikernel (solo5-hvt on Hypervisor.framework) | The agent's key, its chain, its votes |
| A unikernel's service | `pantheon service` on this machine | The node's checkouts and jobs: git, checks, and the inbox backend |
| The inbox server | `scripts/inbox-http.py` on this machine | Each agent's inbox; tokens by their hashes only |
| An agent of `--docker` | Its CLI in a container of its own | Its login, its token. Nothing of `NET` |
| A remote agent | Anywhere with HTTP: a cloud sandbox, another machine, a session here | Its token |

```
pantheon-standalone init NET --repo NAME=DIR [--agents "A B C D"] [--image "A B"|all] [--gateway IP] [--base-port P] [--block-ms N] [--param K=V]...
pantheon-standalone up NET [--docker "A B"|all] [--image "A B"|all] [--backends A=B,...] [--inbox HOST:PORT] [--url URL] [--docker-url URL]
                           [--agent-image IMAGE] [--pass-env VAR,...] [--memory SIZE] [-- NODE ARGS...]
pantheon-standalone connect NET AGENT [--env]   # what a remote agent needs: URL, token, a prompt
pantheon-standalone status NET
pantheon-standalone login NET AGENT             # a container's CLI login, kept in its home volume
pantheon-standalone build-agent [IMAGE]         # the agents' image (this folder's Dockerfile)
pantheon-standalone down NET
```

`pantheon-standalone` alone prints its usage and settings.

## On its own: every agent remote

```bash
integrations/standalone/pantheon-standalone init .net --repo calc=.calc --block-ms 300 --param term_blocks=40
printf -- '- add a sub command\n' > goal.txt
integrations/standalone/pantheon-standalone up .net -- --goal goal.txt --bid-window 300
integrations/standalone/pantheon-standalone connect .net claude
```

`up` starts the four nodes and the inbox server in the background, then
returns. Each node waits for its agent. `connect` prints the agent's inbox
URL, its token, and a prompt to give any coding agent that has tools and
curl. The agent reads `GET /v1/instructions` (`deploy/cloud/agent.md`) and
follows it: it waits for requests, answers drafts, picks and attests as
JSON, and bids by downloading a checkout and handing in a diff.
`GET /v1/status` shows it the market as its node sees it. To run an agent's
CLI in a loop on any machine with sh and curl:

```bash
integrations/standalone/pantheon-standalone connect .net claude --env > claude.env
env $(cat claude.env) sh integrations/standalone/agent-loop.sh
```

The inbox listens on `127.0.0.1:8787` by default. For agents on other
machines, put a tunnel with TLS in front of it (cloudflared), and give its
URL with `--url https://...`. The prompts, and `connect`, then name it.

## Agents in containers

```bash
integrations/standalone/pantheon-standalone build-agent     # once: Claude Code, codex and Grok Build, curl, git, jq
integrations/standalone/pantheon-standalone login .net claude   # once per agent, or pass an API key:
integrations/standalone/pantheon-standalone up .net --docker all --pass-env ANTHROPIC_API_KEY,OPENAI_API_KEY -- --goal goal.txt
```

Each agent of `--docker` gets a container named `pantheon-<net id>-AGENT`
that runs `agent-loop.sh`. The loop runs its provider's CLI headless with
approvals off (the container is the isolation), tells it to work its inbox,
and starts another session whenever one ends. This replaces cmux's
watchdog. `DIPLOMAT_CLI` (the container's `AGENT_CLI`) runs another CLI. A
provider with no default here, such as Muse, needs it.

How the container is run:

- `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--pids-limit=512`,
  `--memory` (default 4g).
- A read-only root, with `/tmp` as a 1 GB tmpfs.
- The home is a named volume (`pantheon-<net id>-AGENT-home`), which keeps
  the CLI's login between runs.
- `agent-loop.sh` is mounted read-only.
- No other mounts: nothing of `NET`, no node home, no checkout, no Docker
  socket.
- The token and URL come in an env file (0600), never on the command line.
- It reaches the inbox at `http://host.docker.internal:PORT` (`--docker-url`).
  Docker Desktop forwards that to this machine. On Linux, `up` adds
  `--add-host=host.docker.internal:host-gateway`. Start the inbox on an
  address the containers can reach (`--inbox 172.17.0.1:8787`, Docker's
  bridge), since a Linux container can't reach the host's 127.0.0.1.

## Nodes as unikernels

A unikernel's address is on the vmnet network, so make the network with
`init --image`. It puts those agents at `GATEWAY's /24 .200+i`, and the
binaries at the host's address on that network so the unikernels can dial
them:

```bash
integrations/standalone/pantheon-standalone init .net --repo calc=.calc --image muse
integrations/standalone/pantheon-standalone up .net --docker muse -- --goal goal.txt
```

For each agent of `--image`, `up` does four things:

1. **Writes its source.** `pantheon image` writes the node's source, with
   its setup, to `integrations/standalone/images/` (git ignores it) with
   mode 0600. The source holds the node's key, and so does the image.
2. **Builds it.** `soma build` turns the source into a solo5 image (`.hvt`,
   0600). The first build fetches MirageOS's dependencies, which takes
   minutes.
3. **Starts its service.** `pantheon service` runs at the gateway's address
   (port: the node's + 1000). It does the node's git, checks and inbox
   backend on the host, and refuses anything else (`runtime/node_service.soma`,
   proved in `runtime/node_service.exp`).
4. **Boots it.** The image boots under `solo5-vmnet` and `solo5-hvt`, with
   its disk at `NET/.standalone/AGENT/disk.img`, which keeps blocks.log,
   signed.log and consensus.state between runs. Its egress is limited with
   `--allow` to the host and the other unikernels, so it has no internet.
   `--isolate` isn't used, because solo5-vmnet's isolation moves the guest to
   a network of its own, away from the host's bridge. If the image stops,
   it is booted again on the same disk.

The tender runs in a deny-all macOS sandbox, and the guest's code pages are
execute-only. `status` reads a unikernel's chain from its disk.

Needs Soma's MirageOS switch (`SOMA_MIRAGE_SWITCH`, default `hvf`) with
`solo5-hvt` and `solo5-vmnet`, `soma` on the PATH, and macOS 26 or later.

The vmnet network's gateway is found in this order, and `init` writes it
down:

1. `PANTHEON_VMNET_GATEWAY`, if set.
2. macOS's `Shared_Net_Address`, if set.
3. The shared bridge that is up now. A Lima VM's socket_vmnet puts it at
   192.168.105.1, and solo5-vmnet's guests join it.
4. Otherwise, macOS's default, 192.168.64.1.

The bridge exists only while some guest runs on it, so `up` boots the
unikernels before their services and the binaries, and the binaries reach
each other through it.

## What it keeps

All its state is in `NET/.standalone/`:

- **`inbox.json` (0600):** the inbox server's config. It holds each inbox
  agent's token hash, inbox, URL and status file.
- **`inbox.log`:** the inbox server's log.
- **`AGENT/token` (0600):** the agent's token. It stays the same between
  runs, so a remote agent's token keeps working.
- **`AGENT/inbox/`:** the agent's inbox.
- **`AGENT/backend.sh`:** the node's backend, `scripts/bidder-inbox.sh` on
  that inbox, with the URL its agent reaches.
- **`AGENT/agent.env` (0600), `AGENT/container`:** a container's settings
  and its id.
- **For a unikernel:** `AGENT/disk.img`, `image.log`, `build.log`,
  `service.log` and `boot.log`.
- **`pids/`:** the processes `up` started, each in a process group of its
  own, which `down` stops.

A binary node's output is appended to `NET/AGENT/node.log`, as with `pantheon up`.

## Isolation, and its limits

What it gives:

- **A remote or container agent never holds a key.** It gets prompts and
  checkouts over HTTP and hands in diffs. Its node checks a diff as it checks
  any bid: `inbox-http.py` refuses symlinks and submodules, and the edits
  are applied by the node.
- **A container sees only its inbox and the internet.** The internet is
  there because the model APIs are on it.
- **A unikernel node holds its key, chain and votes in a VM** whose only
  egress is the host and its peers.

What it doesn't, yet (see the review that led to this, in the U-1 and P-13 items):

- **On the host, every part runs as you:** binary nodes, services, the inbox
  server and the tender. A unikernel's service reads the node's `key.json`
  for the token it shares with the image, and a binary node's model work
  isn't on the host at all here (it's the agents'). The keys sit in plain
  files on this machine either way.
- **The inbox is plain HTTP with bearer tokens.** Keep it on localhost, or
  behind a TLS tunnel.
- **A unikernel's service listens on the vmnet gateway,** where other vmnet
  guests can reach it, with a token sent in the clear. The egress filter
  goes by destination only, so a unikernel may send to every port on the
  host.
- **A unikernel's disk holds about 16 MiB,** and each write rewrites it:
  about 30,000 blocks before the image stops with "disk full". Soma's
  storage needs an append-only log for long runs.
- **A container can reach the internet,** to call its model. It could send
  what it can read (its checkouts, its login) anywhere.
