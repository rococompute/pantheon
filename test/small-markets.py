#!/usr/bin/env python3
"""Real monopoly/oligopoly markets: genesis, work, CI and completion.
No model calls. Run after building main.exe. Failure logs are retained.
"""
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time

here = Path(__file__).resolve().parents[1]
binary = Path(os.environ.get("PANTHEON", here / "main.exe")).resolve()
launcher = here / "integrations/standalone/pantheon-standalone"
root = Path(tempfile.mkdtemp(prefix="pantheon-small-"))
env = dict(os.environ, PANTHEON=str(binary))
running = []
# CI timeout must enter finally too, since the launcher detaches its nodes.
def interrupted(signum, _frame):
    raise SystemExit(128+signum)
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGHUP, interrupted)

def run(*args, cwd=here, timeout=60):
    result = subprocess.run(list(map(str, args)), cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    with (root / "commands.log").open("a") as log:
        log.write(f"{args}\n{result.stdout}\n")
    assert result.returncode == 0, result.stdout
    return result.stdout.strip()

def free_base(n):
    for port in range(32000, 48000, 7):
        sockets = []
        try:
            for i in range(n):
                stream = socket.socket()
                sockets.append(stream)
                stream.bind(("127.0.0.1", port+i))
            return port
        except OSError:
            pass
        finally:
            for stream in sockets:
                stream.close()
    raise AssertionError("no available test port range")

try:
    seed = root / "seed"
    seed.mkdir()
    (seed / "README.md").write_text("Model-free small-market fixture.\n")
    (seed / "test.sh").write_text("#!/bin/sh\nset -eu\ntest -f README.md\n")
    run("git", "init", "-q", cwd=seed)
    run("git", "add", ".", cwd=seed)
    run("git", "-c", "user.name=Test", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture", cwd=seed)
    goal = root / "GOAL.md"
    goal.write_text("- small-market task one\n- small-market task two\n")
    ci = root / "ci-runner"
    ci.write_text('#!/bin/sh\nset -eu\ncd "$2"\nexec sh -c "$3"\n')
    ci.chmod(0o700)
    # Exercise both real launchers and all participants, never a fabricated
    # lower quorum in a four-node genesis.
    for n in (1, 2, 3):
        names = ["alpha", "beta", "gamma"][:n]
        net = root / f"net{n}"
        run(launcher, "init", net, "--repo", f"calc={seed}", "--agents", " ".join(names),
            "--base-port", free_base(n), "--block-ms", "200",
            "--param", "term_blocks=50", "--param", "max_merges=1", "--param", "bid_cooldown=2",
            "--param", "fallback_blocks=60", "--param", "attest_window=160", "--param", "reveal_window=4",
            *([] if n == 1 else ["--param", "finish=1"]))
        genesis = json.loads((net / names[0] / "genesis.json").read_text())
        assert len(genesis["agents"]) == n
        running.append(net)
        run(launcher, "up", net, "--backends", ",".join(f"{a}=scripted" for a in names), "--",
            "--goal", goal, "--bid-window", "4", "--listen", "127.0.0.1",
            "--ci-repo", "calc", "sh test.sh", "--ci-sandbox", ci)
        deadline = time.monotonic()+150
        while True:
            statuses = [(net / a / "status.txt").read_text() if (net / a / "status.txt").exists() else "" for a in names]
            if all(re.search(r"^finished:", s, re.M) for s in statuses):
                break
            assert time.monotonic() < deadline, f"{n}-node completion timeout; logs: {net}"
            time.sleep(1)
        run(launcher, "down", net)
        running.remove(net)
        blocks = [[json.loads(line) for line in (net / a / "blocks.log").read_text().splitlines()] for a in names]
        longest = max(blocks, key=len)
        assert all(log == longest[:len(log)] for log in blocks), "nodes disagree on blocks"
        heads = [run("git", "rev-parse", "HEAD", cwd=net/a/"repos/calc") for a in names]
        assert len(set(heads)) == 1, "governed heads disagree"
        status = (net / names[0] / "status.txt").read_text()
        mode = "monopoly" if n == 1 else "oligopoly"
        assert f"market-mode {mode}\n" in status, "missing market mode label"
        snapshot = json.loads(run(binary, "status", net/names[0], "--json"))
        assert snapshot["mode"] == mode and snapshot["validators"] == n
        accepted = {int(m[0]): m[1] for m in re.findall(r"^bid (\d+) \[merged\] task \d+ by (\S+)", status, re.M)}
        assert len(accepted) >= 2, "work did not merge"
        history = re.search(r"^history\s+(.*)$", status, re.M).group(1).split()
        assert set(names).issubset(history), "leadership did not rotate through everyone"
        proposed, yes_votes = {}, {}
        for block in longest:
            for raw in block["txs"]:
                tx = json.loads(raw)
                fields, author = tx["fields"], tx["agent"]
                if fields[0] == "merge":
                    bid = int(fields[1])
                    proposed[bid] = author
                    yes_votes[bid] = []
                elif fields[0] == "attest" and fields[2] == "yes":
                    yes_votes.setdefault(int(fields[1]), []).append(author)
        for bid, contributor in accepted.items():
            leader = proposed[bid]
            assert (contributor == leader) == (n == 1), "wrong self-review policy"
            reviewers = [a for a in yes_votes.get(bid, []) if a not in (leader, contributor)]
            if n == 3:
                assert reviewers, "three-node merge omitted independent attestation"
            else:
                assert not reviewers, "small market invented an independent reviewer"
        logs = "\n".join((net / a / "node.log").read_text() for a in names)
        assert re.search(r"CI for request .*: passed", logs), "no actual successful CI checks"
        print(f"PASS {mode} ({n} nodes): {len(accepted)} merges, CI, review policy, history and completion", flush=True)
    print(f"PASS small markets; zero model calls; logs: {root}", flush=True)
finally:
    for net in running:
        subprocess.run([str(launcher), "down", str(net)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=45)
    print(f"Retained {root}", flush=True)
