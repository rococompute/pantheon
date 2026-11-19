#!/usr/bin/env python3
"""Read committed status, publish local events, and steer diplomats via cmux hooks or c11 mail."""
import argparse
import fcntl
import hashlib
import json
import math
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
        "term": int(header[2]),
        "leader": header[3],
        "leader_chain": next(({"count": int(count), "tip": tip} for count, tip in
                              re.findall(r"^leader-chain (\d+) ([0-9a-f]*)$", text, re.M)),
                             {"count": 0, "tip": ""}),
        "tasks": dict(re.findall(r"^task (\d+) \[(open|closed)\] ", text, re.M)),
        "bids": {bid: state.split()[0] for bid, state in
                 re.findall(r"^bid (\d+) \[([^\]]+)\] ", text, re.M)},
        "repos": dict(re.findall(r"^repo (\S+) ([0-9a-f]+)$", text, re.M)),
        "finished": bool(re.search(r"^finished:", text, re.M)),
    }


def same_snapshot(left, right):
    # Older relay state files did not persist the already-present term.
    return all(right.get(key) == value for key, value in left.items())


def observe_status(path, now, max_age):
    try:
        before = path.stat()
        text = path.read_text().strip()
        after = path.stat()
        stamp = lambda item: (item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
        if stamp(before) != stamp(after):
            return None, {"state": "changing"}
    except (OSError, UnicodeError):
        return None, {"state": "unavailable"}
    try:
        parsed = status(text)
    except ValueError:
        parsed = None
    if parsed is None:
        return None, {"state": "incomplete"}
    info = {"state": "available", "height": parsed["height"], "modified": after.st_mtime}
    if now - after.st_mtime > max_age or after.st_mtime - now > max_age:
        info["state"] = "stale"
        return None, info
    return parsed, info


def select_status(net, agents, old, now, max_age):
    """Observe local committed status, never vote on or alter consensus.

    Use the greatest recently observed height. Equal-height disagreement
    freezes progress notices instead of arbitrarily interpreting one side.
    Equal identical views use the lexical agent name for reproducibility.
    """
    candidates, nodes = [], {}
    for agent in agents:
        snapshot, info = observe_status(net / agent / "status.txt", now, max_age)
        nodes[agent] = info
        if snapshot is not None:
            candidates.append((agent, snapshot))
    source = {"state": "unavailable", "agent": None, "height": None, "nodes": nodes}
    if not candidates:
        if any(info["state"] == "stale" for info in nodes.values()):
            source["state"] = "stale"
        return None, source
    highest = max(snapshot["height"] for _, snapshot in candidates)
    leaders = sorted((agent, snapshot) for agent, snapshot in candidates if snapshot["height"] == highest)
    source["height"] = highest
    if any(snapshot != leaders[0][1] for _, snapshot in leaders[1:]):
        source["state"] = "conflict"
        return None, source
    agent, snapshot = leaders[0]
    if old and highest < old["height"]:
        source["state"] = "behind"
        return None, source
    if old and highest == old["height"] and not same_snapshot(old, snapshot):
        source["state"] = "conflict"
        return None, source
    source.update(state="available", agent=agent)
    return snapshot, source


def transitions(old, new):
    if old:
        journal = new["leader_chain"]
        if journal["count"] > old.get("leader_chain", {}).get("count", 0):
            yield {"type": "leader-chain.updated", **journal}
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


def notice(events, desk, compact=False):
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
        elif kind == "leader-chain.updated":
            parts.append("Leader handoff journal advanced through record #" + str(event["count"]) +
                         ". Read leader-chain for new check results and findings; these are not merge approvals.")
    if compact:
        return ("Pantheon event update: " + " ".join(parts) + "\n"
                "Read your diplomat instructions and use your inbox wrapper to list requests. "
                "Answer waiting kind=answer requests, then resume useful patch work. "
                "Recheck committed status before submitting for a closed task. Preserve edits before skipping. "
                "These notices do not authorize dropping work or approving an unreviewed contribution.")
    return ("Pantheon event update: " + " ".join(parts) + "\n"
            "At the next safe tool boundary, read " + str(desk / "instructions.md") + ". "
            "Use " + str(desk / "pantheon-inbox") + " list. Answer waiting kind=answer requests "
            "promptly, then resume useful patch work. Recheck committed status before submitting a patch "
            "for a closed task. Preserve edits before skipping; skip can remove the request checkout. "
            "These notices do not authorize dropping work or approving an unreviewed contribution.")


class Bridge:
    def __init__(self, net, cmux, wait=False, state=".cmux", c11=None, status_max_age=30):
        # cmux delivers through `cmux agent message`; with c11 set (its CLI),
        # notices go as c11 mail from Pantheon, rung at the agent's next idle.
        self.net, self.cmux, self.c11 = Path(net).resolve(), cmux, c11
        if not math.isfinite(status_max_age) or status_max_age <= 0:
            raise ValueError("status_max_age must be positive")
        self.status_max_age = status_max_age
        self.root = self.net / state
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
        now = time.time()
        old = self.state["snapshot"]
        previous_source = self.state.get("source")
        new, source = select_status(self.net, self.agents(), old, now, self.status_max_age)
        targets = self.targets()
        events = [(event, [new["leader"]] if new["leader"] in targets else [])
                  if event["type"] == "leader-chain.updated" else (event, list(targets))
                  for event in transitions(old, new)] if new is not None else []
        # Availability is an observation for subscribers/operators, not an
        # instruction, consensus decision or terminal market transition.
        previous_mode = previous_source.get("state") if previous_source else None
        if previous_mode != source["state"] and (previous_source or source["state"] != "available"):
            events.append(({"type": "relay.status", "status": source["state"],
                            "source": source["agent"], "observed_height": source["height"]}, []))
        current = new or old
        active = {}
        # A dead/lagging status source must not block local inbox notices.
        if not current or not current["finished"]:
            for agent in targets:
                active[agent] = requests(self.root / agent / "inbox", now)
                for rid, kind in active[agent].items():
                    if rid not in self.state["requests"].get(agent, {}):
                        events.append(({"type": "request.ready", "agent": agent,
                                        "request": rid, "kind": kind}, [agent]))
        if new is not None:
            self.state["snapshot"] = new
        self.state["source"] = source
        self.state["requests"] = active
        for event, recipients in events:
            self.state["seq"] += 1
            event.update(seq=self.state["seq"], height=current["height"] if current else 0, time=now)
            self.state["events"].append(event)
            for agent in recipients:
                queue = self.state["outbox"].setdefault(agent, [])
                queue.append(event)
                del queue[:-256]
        self.state["events"] = self.state["events"][-256:]
        # Persist the outbox before delivery: a crash can duplicate a notice,
        # but cannot acknowledge it before cmux/C11 has accepted it.
        if new != old or events or source != previous_source or active != getattr(self, "active", None):
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
            # c11 mail bodies are at most 4096 bytes: send fewer events at once.
            while self.c11 and len(batch) > 1 and len(text.encode()) > 4000:
                batch = batch[:len(batch) // 2]
                text = notice(batch, self.root / agent / "desk")
            if self.c11:
                if len(text.encode()) > 4000:
                    text = notice(batch, self.root / agent / "desk", compact=True)
                if len(text.encode()) > 4000:
                    # Never acknowledge an event whose full notice was not sent.
                    print("pantheon events: one event exceeds c11 mail's size limit for " + agent,
                          flush=True)
                    self.retry[agent] = time.monotonic() + 30
                    continue
                command = [self.c11, "mailbox", "send", "--to", "id:" + surface, "--from", "Pantheon",
                           "--topic", "pantheon.events", "--body", text]
            else:
                command = [self.cmux, "agent", "message", surface, "--from", "Pantheon", "--", text]
            try:
                subprocess.run(command, check=True, timeout=5, stdout=subprocess.DEVNULL,
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
                    replay = [{"type": "snapshot", "seq": self.state["seq"], "state": self.state["snapshot"],
                               "source": self.state.get("source")}]
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
    parser.add_argument("--c11", help="deliver as c11 mail with this c11 CLI instead of cmux hooks")
    parser.add_argument("--state", default=".cmux", help="NET's directory for the integration's state")
    parser.add_argument("--parent", type=int)
    parser.add_argument("--status-max-age", type=float, default=30,
                        help="ignore status snapshots older than this many seconds (default: 30)")
    args = parser.parse_args()
    # A replacement watchdog can start before the previous relay exits.
    # Wait for its lock rather than leaving the new watchdog without a relay.
    if not math.isfinite(args.status_max_age) or args.status_max_age <= 0:
        parser.error("--status-max-age must be positive")
    bridge = Bridge(args.net, args.cmux, wait=True, state=args.state, c11=args.c11,
                    status_max_age=args.status_max_age)
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
