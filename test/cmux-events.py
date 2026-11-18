#!/usr/bin/env python3
"""Event-to-hook delivery without a running cmux or market."""
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

source = Path(__file__).resolve().parents[1] / "integrations/cmux/events.py"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("events", source)
events = importlib.util.module_from_spec(spec)
spec.loader.exec_module(events)


def status(height=1, bid="pending", task="open", finished=False):
    return (f"height {height}  term 1  leader claude-1\nversion 3\n"
            f"repo wallet {'a' * 40}\ntask 1 [{task}] wallet: multi-line spec\nmore spec\n"
            f"bid 2 [{bid}] task 1 by codex-1 reason\nverdict 2 this is merely proposed\n"
            + ("finished: done\n" if finished else "") + "pool 0\n")


class TestEvents(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.net = Path(self.temp.name) / "net"
        self.net.mkdir()
        for agent in ("claude-1", "codex-1"):
            home = self.net / agent
            home.mkdir()
            for name in ("key.json", "genesis.json"):
                (home / name).write_text("{}")
            desk = self.net / ".cmux" / agent
            (desk / "inbox").mkdir(parents=True)
            (desk / "surface").write_text("surface-" + agent)
        self.output = self.net / "calls.jsonl"
        self.cmux = self.net / "cmux"
        self.cmux.write_text("#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n"
                             "root=Path(__file__).parent\n"
                             "if (root/'fail').exists(): sys.exit(1)\n"
                             "with (root/'calls.jsonl').open('a') as out: out.write(json.dumps(sys.argv[1:])+'\\n')\n")
        self.cmux.chmod(0o755)
        self.bridge = events.Bridge(self.net, str(self.cmux))
        self.write(status())

    def tearDown(self):
        self.bridge.close()
        self.temp.cleanup()

    def write(self, text):
        (self.net / "claude-1/status.txt").write_text(text)

    def request(self, rid="123-abcd", agent="codex-1", kind="answer"):
        path = self.net / ".cmux" / agent / "inbox" / rid
        path.mkdir()
        for name, text in (("deadline", str(int(time.time()) + 600)), ("kind", kind),
                           ("prompt.txt", "agent-authored prompt that must not be copied")):
            (path / name).write_text(text)
        return path

    def calls(self):
        return [json.loads(line) for line in events.read(self.output).splitlines()]

    def test_committed_only_baseline_and_dedup(self):
        self.write(status(bid="merged", task="closed"))
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.calls(), [])  # Attaching does not replay history.
        self.write(status(2, "pending", "open"))
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.calls(), [])  # A proposed verdict is not a merge.
        self.write(status(3, "merged", "closed"))
        self.bridge.poll()
        self.bridge.deliver()
        self.bridge.poll()
        self.bridge.deliver()
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][:5], ["agent", "message", "surface-claude-1", "--from", "Pantheon"])
        self.assertIn("Task #1 closed", calls[0][-1])
        self.assertIn("Contribution #2 merged", calls[0][-1])
        self.assertNotIn("merely proposed", calls[0][-1])

    def test_request_target_filtering_and_durable_retry(self):
        self.bridge.poll()
        path = self.request()
        claimed = self.request("124-abcd")
        (claimed / "claimed").touch()
        replied = self.request("125-abcd")
        (replied / "reply.txt").touch()
        expired = self.request("126-abcd")
        (expired / "deadline").write_text("1")
        (self.net / "fail").touch()
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.calls(), [])
        self.bridge.close()
        self.bridge = events.Bridge(self.net, str(self.cmux))
        (self.net / "fail").unlink()
        self.bridge.poll()
        self.bridge.deliver()
        calls = self.calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][2], "surface-codex-1")
        self.assertIn("123-abcd", calls[0][-1])
        self.assertNotIn("agent-authored", calls[0][-1])
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue((path / "prompt.txt").exists())  # No automatic cancellation.

    def test_withdrawn_request_not_delivered_after_retry(self):
        path = self.request()
        self.bridge.poll()
        (path / "claimed").touch()
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.calls(), [])

    def test_partial_or_older_status_is_ignored(self):
        self.write(status(8))
        self.bridge.poll()
        self.write(status(9, "merged", "closed").replace("pool 0\n", ""))
        self.bridge.poll()
        self.write(status(7, "merged", "closed"))
        self.bridge.poll()
        self.assertEqual(self.bridge.state["seq"], 0)
        self.assertEqual(self.bridge.state["snapshot"]["height"], 8)

    def test_terminal_states_with_stale_marker(self):
        self.bridge.poll()
        self.write(status(2, "merged stale"))
        self.bridge.poll()
        self.assertEqual(self.bridge.state["events"][-1]["type"], "contribution.merged")
        self.write(status(3, "withdrawn"))
        self.bridge.poll()
        self.assertEqual(self.bridge.state["events"][-1]["type"], "contribution.withdrawn")

    def subscribe(self, after=None):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(2)
        client.connect(str(self.bridge.address))
        client.sendall((json.dumps({"after": after}) + "\n").encode())
        self.bridge.sockets(0.1)
        self.bridge.sockets(0.1)
        return client

    def test_socket_snapshot_live_replay_and_gap(self):
        self.bridge.poll()
        self.bridge.listen()
        with self.subscribe() as client:
            baseline = json.loads(client.recv(65536))
            self.assertEqual(baseline["type"], "snapshot")
            self.write(status(2, "merged", "closed"))
            self.bridge.poll()
            batch = [json.loads(line) for line in client.recv(65536).splitlines()]
            self.assertEqual([e["seq"] for e in batch], [1, 2])
        with self.subscribe(after=1) as client:
            self.assertEqual(json.loads(client.recv(65536))["type"], "task.closed")
        with self.subscribe(after=-5) as client:
            self.assertEqual(json.loads(client.recv(65536))["type"], "snapshot")

    def test_singleton_and_finish(self):
        with self.assertRaises(BlockingIOError):
            events.Bridge(self.net, str(self.cmux))
        self.write(status(finished=True))
        self.bridge.poll()
        self.bridge.deliver()
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(len(self.calls()), 2)
        self.assertTrue(all("market status is finished" in c[-1] for c in self.calls()))

    def test_service_shutdown_cleans_socket(self):
        proc = subprocess.Popen(["python3", str(source), str(self.net), "--cmux", str(self.cmux)])
        try:
            discovery = self.net / ".cmux/events/socket"
            time.sleep(0.1)
            self.assertIsNone(proc.poll())  # Replacement waits for the old relay.
            self.assertFalse(discovery.exists())
            self.bridge.close()
            end = time.monotonic() + 5
            while not discovery.exists() and time.monotonic() < end:
                time.sleep(0.02)
            address = events.read(discovery)
            self.assertTrue(address)
            self.write(status(2, finished=True))
            proc.terminate()
            self.assertEqual(proc.wait(timeout=10), 0)
            self.assertFalse(Path(address).exists())
            self.assertFalse(discovery.exists())
            self.assertEqual(len(self.calls()), 2)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        self.bridge = events.Bridge(self.net, str(self.cmux))


if __name__ == "__main__":
    unittest.main()
