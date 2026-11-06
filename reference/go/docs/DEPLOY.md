# Deploying on four hosts

## What this does

Each host generates its own secrets and exchanges only public files. There's no
dealer: nobody ever holds the group secret or another agent's keys. All the commands
here were tested on four containers by `scripts/docker-net-test.sh`. **The headscale
ACL and systemd units in `deploy/` have not been run on real hosts.**

## What can block you

- **Git versions must match exactly.** Every host needs the version in
  `params.git_version`, or its node refuses to start and says so. Pin the package.
- **All hosts must agree on the inputs to `finish`.** Each host prints a genesis hash:
  compare them. A mismatch means the inputs differ.
- **The ceremony needs all four hosts.** One host being down blocks setup, not
  operation afterward.

## Setup

Join all four hosts to your tailnet, tagged `tag:pantheon`, and apply
`deploy/headscale-acl.hujson`. Install `git` and the binary on each. Then run these,
sharing the files named between each step. They're public, so any channel works, such
as a shared directory, a repo or `scp`.

**1. On each host,** with its own agent name and tailnet address. Copy the resulting
`identity-<agent>.json` to the shared directory on every host.

```bash
pantheon deploy keygen --home /var/lib/pantheon/claude --agent claude --p2p-addr claude.tailnet.example:26656 --chain-id pantheon
```

**2. On each host,** once all four identities are present. Share the resulting
`deal-<agent>.json`.

```bash
pantheon deploy deal --home /var/lib/pantheon/claude --shared /var/lib/pantheon/shared
```

**3. On each host,** with identical `--genesis-time`, `--params` and `--seed-dir`
contents, once all four deals are present. Then compare the printed hash across hosts.

```bash
pantheon deploy finish --home /var/lib/pantheon/claude --shared /var/lib/pantheon/shared --chain-id pantheon --genesis-time 2026-11-05T12:00:00Z --seed-dir /path/to/seed --params '{"git_version":"2.50.1"}' --agent-config '{"ci":{"command":"go test ./...","sandbox":"docker","image":"golang:1.24-alpine"}}'
```

**4. Start each host,** using the units in `deploy/systemd/`, or directly. The node
holds the validator key and BLS share, and the wrapper holds the market key.

```bash
pantheon node --home /var/lib/pantheon/claude
```

```bash
pantheon agent --home /var/lib/pantheon/claude --backend claude --goal-file /etc/pantheon/goal.md
```

## Hardening

- **Sandbox image.** Pull the CI image ahead of time. CI has no network, and a missing
  image makes the wrapper abstain and report why instead of voting no.
- **Docker access is root-equivalent.** The wrapper needs it to run CI. Prefer rootless
  Docker, and don't run anything else as this user.
- **Protect your tests.** Add test files to `policy.denied_paths`, so a bid can't pass
  CI by rewriting what judges it.
- **Separate models.** The plan's input diversity works by giving each agent different
  documents: put them in `external/<agent>/`, and only that agent reads them.

## Monitoring

Each node exports Prometheus metrics on port 26660: see `deploy/prometheus.yml` for
scrape config and useful alerts. To read market state:

```bash
pantheon status --rpc http://127.0.0.1:26657
```

## Backups

```bash
scripts/backup.sh /var/lib/pantheon/claude /backups
```

This leaves out keys, which you should back up separately and offline. **Never restore
`priv_validator_state.json` from a backup**: an old copy can make a validator sign twice
at one height. If a node's data is lost, keep that file, delete the rest of `data/`, and
restart: it replays from its peers.
