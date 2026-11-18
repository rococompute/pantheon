#!/usr/bin/env python3
"""Read committed status, publish local events, and steer diplomats via cmux hooks."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import time


def read(path):
    try:
        return path.read_text().strip()
    except (OSError, UnicodeError):
        return ""


def status(text):
    header = re.match(r"height (\d+)  term (\d+)  leader (\S+)\n", text)
    if not header or not re.search(r"^pool \d+$", text, re.M):
        return None  # Do not interpret an incomplete write as removals.
    return {
        "height": int(header[1]),
        "tasks": dict(re.findall(r"^task (\d+) \[(open|closed)\] ", text, re.M)),
        "bids": {bid: state.split()[0] for bid, state in
                 re.findall(r"^bid (\d+) \[([^\]]+)\] ", text, re.M)},
        "repos": dict(re.findall(r"^repo (\S+) ([0-9a-f]+)$", text, re.M)),
        "finished": bool(re.search(r"^finished:", text, re.M)),
    }


def transitions(old, new):
    if old:
        for bid, state in new["bids"].items():
            if state in ("merged", "rejected", "cleared", "withdrawn") and old["bids"].get(bid) != state:
                yield {"type": "contribution." + state, "bid": bid}
        for task, state in new["tasks"].items():
            if state == "closed" and old["tasks"].get(task) != state:
                yield {"type": "task.closed", "task": task}
    if new["finished"] and (not old or not old["finished"]):
        yield {"type": "market.finished"}


def requests(inbox, now):
    result = {}
    for path in inbox.glob("*-*"):
        if not re.fullmatch(r"\d+-[0-9a-f]+", path.name):
            continue
        try:
            deadline = int(read(path / "deadline"))
        except ValueError:
            continue
        kind = read(path / "kind")
        if (deadline > now and kind in ("answer", "patch") and (path / "prompt.txt").is_file()
                and not any((path / f).exists() for f in ("claimed", "expired", "reply.txt", "done"))):
            result[path.name] = kind
    return result


def notice(events, desk):
    parts = []
    for event in events:
        kind = event["type"]
        if kind.startswith("contribution."):
            parts.append("Contribution #" + event["bid"] + " " + kind.split(".")[1] + ".")
        elif kind == "task.closed":
            parts.append("Task #" + event["task"] + " closed.")
        elif kind == "market.finished":
            parts.append("The committed market status is finished. Check your inbox's finish notice and stop.")
        elif kind == "request.ready":
            parts.append("Inbox request " + event["request"] + " (" + event["kind"] + ") is waiting.")
    return ("Pantheon event update: " + " ".join(parts) + "\n"
            "At the next safe tool boundary, read " + str(desk / "instructions.md") + ". "
            "Use " + str(desk / "pantheon-inbox") + " list. Answer waiting kind=answer requests "
            "promptly, then resume useful patch work. Recheck committed status before submitting a patch "
            "for a closed task. Preserve edits before skipping; skip can remove the request checkout. "
            "These notices do not authorize dropping work or approving an unreviewed contribution.")


class Bridge:
    def __init__(self, net, cmux, wait=False):
        self.net, self.cmux = Path(net).resolve(), cmux
        self.root = self.net / ".cmux"
        self.directory = self.root / "events"
        self.directory.mkdir(parents=True, exist_ok=True)
        self.lock = (self.directory / "lock").open("w")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except OSError:
            self.lock.close()
            raise
        self.file = self.directory / "state.json"
        self.state = json.loads(read(self.file) or '{"seq":0,"snapshot":null,"events":[],"outbox":{},"requests":{}}')
        self.retry = {}
        self.clients = {}
        self.server = None

    def agents(self):
        return sorted(p.name for p in self.net.iterdir()
                      if (p / "key.json").is_file() and (p / "genesis.json").is_file())

    def targets(self):
        return {a: read(self.root / a / "surface") for a in self.agents()
                if read(self.root / a / "surface")}

    def save(self):
        tmp = self.file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state) + "\n")
        tmp.replace(self.file)

    def poll(self):
        agents = self.agents()
        new = status(read(self.net / agents[0] / "status.txt")) if agents else None
        old = self.state["snapshot"]
        if new is None or (old and new["height"] < old["height"]):
            return
        targets = self.targets()
        events = [(e, list(targets)) for e in transitions(old, new)]
        active = {}
        if not new["finished"]:
            for agent in targets:
                active[agent] = requests(self.root / agent / "inbox", time.time())
                for rid, kind in active[agent].items():
                    if rid not in self.state["requests"].get(agent, {}):
                        events.append(({"type": "request.ready", "agent": agent,
                                        "request": rid, "kind": kind}, [agent]))
        self.state["snapshot"] = new
        self.state["requests"] = active
        for event, recipients in events:
            self.state["seq"] += 1
            event.update(seq=self.state["seq"], height=new["height"], time=time.time())
            self.state["events"].append(event)
            for agent in recipients:
                queue = self.state["outbox"].setdefault(agent, [])
                queue.append(event)
                del queue[:-256]
        self.state["events"] = self.state["events"][-256:]
        # Persist the outbox before delivery: a crash can duplicate a notice,
        # but cannot acknowledge it before cmux has accepted it.
        if new != old or events or active != getattr(self, "active", None):
            self.save()
        self.active = active
        for event, _ in events:
            for client in list(self.clients):
                if self.clients[client] is None:
                    self.send(client, [event])

    def deliver(self):
        for agent, surface in self.targets().items():
            queue = self.state["outbox"].get(agent, [])
            queue[:] = [e for e in queue if e["type"] != "request.ready"
                        or e["request"] in self.state["requests"].get(agent, {})]
            if (self.root / agent / "inbox/limited").exists():
                continue
            if not queue or time.monotonic() < self.retry.get(agent, 0):
                continue
            # Bound a provider message without dropping the rest of the queue.
            batch = queue[:32]
            text = notice(batch, self.root / agent / "desk")
            try:
                subprocess.run([self.cmux, "agent", "message", surface, "--from", "Pantheon",
                                "--", text], check=True, timeout=5, stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE)
            except (OSError, subprocess.SubprocessError) as error:
                print("pantheon events: hook delivery failed for " + agent + " (" +
                      type(error).__name__ + "); retrying in 30s", flush=True)
                self.retry[agent] = time.monotonic() + 30
                continue
            print("pantheon events: delivered through #" + str(batch[-1]["seq"]) + " to " + agent, flush=True)
            del queue[:len(batch)]
            self.save()

    def listen(self):
        # macOS Unix paths are limited to ~104 bytes, even when NET is long.
        directory = Path("/tmp") / ("pantheon-events-" + str(os.getuid()))
        directory.mkdir(mode=0o700, exist_ok=True)
        info = directory.lstat()
        if not directory.is_dir() or directory.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError("event socket directory must be private and owned by this user")
        self.address = directory / (hashlib.sha256(str(self.net).encode()).hexdigest()[:24] + ".sock")
        self.address.unlink(missing_ok=True)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.address))
        os.chmod(self.address, 0o600)
        self.server.listen(8)
        self.server.setblocking(False)
        (self.directory / "socket").write_text(str(self.address) + "\n")

    def send(self, client, events):
        data = b"".join((json.dumps(e) + "\n").encode() for e in events)
        try:
            # Disconnect slow readers; they reconnect with the last sequence ID.
            if client.send(data) != len(data):
                raise OSError("slow subscriber")
        except OSError:
            self.clients.pop(client, None)
            client.close()

    def sockets(self, timeout):
        ready, _, _ = select.select([self.server] + list(self.clients), [], [], timeout)
        for stream in ready:
            if stream is self.server:
                client, _ = self.server.accept()
                client.setblocking(False)
                if len(self.clients) >= 16:
                    client.close()
                else:
                    self.clients[client] = b""
                continue
            try:
                data = stream.recv(1024)
                buf = self.clients[stream]
                if not data or buf is None or len(buf) + len(data) > 1024:
                    raise ValueError("closed or invalid subscriber")
                buf += data
                self.clients[stream] = buf
                if b"\n" not in buf:
                    continue
                after = json.loads(buf.split(b"\n")[0]).get("after")
                events = self.state["events"]
                if type(after) is int and (events[0]["seq"] - 1 if events else self.state["seq"]) <= after <= self.state["seq"]:
                    replay = [e for e in events if e["seq"] > after]
                else:
                    replay = [{"type": "snapshot", "seq": self.state["seq"], "state": self.state["snapshot"]}]
                self.clients[stream] = None
                if replay:
                    self.send(stream, replay)
            except (OSError, ValueError, AttributeError):
                self.clients.pop(stream, None)
                stream.close()

    def close(self):
        for client in self.clients:
            client.close()
        if self.server:
            self.server.close()
            self.address.unlink(missing_ok=True)
            (self.directory / "socket").unlink(missing_ok=True)
        self.lock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("net")
    parser.add_argument("--cmux", default=os.environ.get("CMUX", "cmux"))
    parser.add_argument("--parent", type=int)
    args = parser.parse_args()
    # A replacement watchdog can start before the previous relay exits.
    # Wait for its lock rather than leaving the new watchdog without a relay.
    bridge = Bridge(args.net, args.cmux, wait=True)
    running = True

    def stop(*_):
        nonlocal running
        running = False

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, stop)
    try:
        bridge.poll()
        bridge.listen()
        next_poll = 0
        while running:
            if args.parent and os.getppid() != args.parent:
                break
            if time.monotonic() >= next_poll:
                bridge.poll()
                bridge.deliver()
                next_poll = time.monotonic() + 2
            bridge.sockets(0.5)
        # Include a finish committed immediately before watchdog shutdown.
        bridge.poll()
        bridge.deliver()
    finally:
        bridge.close()


if __name__ == "__main__":
    main()
