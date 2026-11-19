#!/usr/bin/env python3
"""Event-to-hook delivery without a running cmux or market."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

source = Path(os.environ.get("PANTHEON_EVENTS_SOURCE", str(Path(__file__).resolve().parents[1] / "integrations/cmux/events.py")))
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

    def write(self, text, agent="claude-1"):
        (self.net / agent / "status.txt").write_text(text)

    def request(self, rid="123-abcd", agent="codex-1", kind="answer"):
        path = self.net / ".cmux" / agent / "inbox" / rid
        path.mkdir()
        for name, text in (("deadline", str(int(time.time()) + 600)), ("kind", kind),
                           ("prompt.txt", "agent-authored prompt that must not be copied")):
            (path / name).write_text(text)
        return path

    def calls(self):
        return [json.loads(line) for line in events.read(self.output).splitlines()]

    def test_c11_batches_preserve_every_event_and_utf8(self):
        self.bridge.c11 = str(self.cmux)
        queue = [{"type": "task.closed", "task": str(i), "seq": i}
                 for i in range(1, 200)]
        self.bridge.state["outbox"]["claude-1"] = list(queue)
        while self.bridge.state["outbox"]["claude-1"]:
            self.bridge.deliver()
        calls = self.calls()
        bodies = [call[call.index("--body") + 1] for call in calls]
        self.assertTrue(all(len(body.encode()) <= 4000 for body in bodies))
        self.assertTrue(all(call[:3] == ["mailbox", "send", "--to"] for call in calls))
        joined = "\n".join(bodies)
        for event in queue:
            self.assertEqual(joined.count("Task #" + event["task"] + " closed."), 1)
        self.assertTrue(all("unreviewed contribution" in body for body in bodies))

    def test_c11_long_paths_use_complete_compact_notice(self):
        self.bridge.c11 = str(self.cmux)
        self.bridge.state["outbox"]["claude-1"] = [
            {"type": "task.closed", "task": "123", "seq": 1}]
        original = events.notice
        def long_notice(batch, desk, compact=False):
            return original(batch, Path("/" + "🌱" * 1200), compact=compact)
        with patch.object(events, "notice", side_effect=long_notice):
            self.bridge.deliver()
        body = self.calls()[0][-1]
        self.assertLessEqual(len(body.encode()), 4000)
        self.assertIn("Task #123 closed.", body)
        self.assertTrue(body.endswith("approving an unreviewed contribution."))
        self.assertEqual(self.bridge.state["outbox"]["claude-1"], [])

    def test_c11_oversized_event_is_not_acknowledged(self):
        self.bridge.c11 = str(self.cmux)
        queue = [{"type": "task.closed", "task": "9" * 5000, "seq": 1}]
        self.bridge.state["outbox"]["claude-1"] = list(queue)
        self.bridge.deliver()
        self.assertEqual(self.bridge.state["outbox"]["claude-1"], queue)
        self.assertFalse(self.output.exists())

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

    def test_journal_update_targets_only_current_leader(self):
        self.bridge.poll()
        self.write(status(2).replace("pool 0", "leader-chain 3 " + "a" * 64 + "\npool 0"))
        self.bridge.poll()
        self.bridge.deliver()
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0][2], "surface-claude-1")
        self.assertIn("record #3", self.calls()[0][-1])
        self.assertEqual(self.bridge.state["events"][-1]["type"], "leader-chain.updated")

    def test_partial_or_older_status_is_ignored(self):
        self.write(status(8))
        self.bridge.poll()
        self.write(status(9, "merged", "closed").replace("pool 0\n", ""))
        self.bridge.poll()
        self.write(status(7, "merged", "closed"))
        self.bridge.poll()
        self.assertTrue(all(event["type"] == "relay.status" for event in self.bridge.state["events"]))
        self.assertEqual(self.bridge.state["source"]["state"], "behind")
        self.assertEqual(self.bridge.state["snapshot"]["height"], 8)

    def test_missing_first_node_uses_another_complete_status(self):
        (self.net / "claude-1/status.txt").unlink()
        self.write(status(4), "codex-1")
        self.bridge.poll()
        self.assertIsNotNone(self.bridge.state["snapshot"])
        self.assertEqual(self.bridge.state["snapshot"]["height"], 4)
        self.assertEqual(self.bridge.state["source"]["agent"], "codex-1")

    def test_lagging_first_node_does_not_stall_committed_progress(self):
        self.bridge.poll()
        self.write(status(3, "merged", "closed"), "codex-1")
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 3)
        self.assertEqual(len(self.calls()), 2)
        self.assertTrue(all("Contribution #2 merged" in call[-1] for call in self.calls()))

    def test_stale_higher_status_is_not_selected_on_attachment(self):
        self.write(status(90, "merged", "closed"))
        past = time.time() - 120
        os.utime(self.net / "claude-1/status.txt", (past, past))
        self.write(status(4), "codex-1")
        self.bridge.poll()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 4)
        self.assertEqual(self.bridge.state["source"]["nodes"]["claude-1"]["state"], "stale")
        self.assertEqual(self.bridge.state["seq"], 0)

    def test_equal_identical_views_choose_lexical_source(self):
        self.write(status(5), "codex-1")
        self.write(status(5))
        self.bridge.poll()
        self.assertEqual(self.bridge.state["source"]["agent"], "claude-1")
        self.assertEqual(self.bridge.state["snapshot"]["height"], 5)

    def test_equal_height_disagreement_freezes_then_recovers(self):
        self.bridge.poll()
        self.write(status(2))
        self.write(status(2, "merged", "closed"), "codex-1")
        self.bridge.poll()
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 1)
        self.assertEqual(self.bridge.state["source"]["state"], "conflict")
        self.assertEqual(self.calls(), [])
        self.assertEqual([event["type"] for event in self.bridge.state["events"]], ["relay.status"])
        self.write(status(3, "merged", "closed"))
        self.write(status(3, "merged", "closed"), "codex-1")
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 3)
        self.assertEqual(self.bridge.state["source"]["state"], "available")
        self.assertEqual(len(self.calls()), 2)

    def test_same_height_mutation_cannot_invent_a_commit(self):
        self.bridge.poll()
        self.write(status(1, "merged", "closed"))
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.bridge.state["snapshot"]["bids"]["2"], "pending")
        self.assertEqual(self.bridge.state["source"]["state"], "conflict")
        self.assertEqual(self.calls(), [])

    def test_unavailable_status_keeps_inbox_nudges_and_exposes_source_state(self):
        self.bridge.poll()
        (self.net / "claude-1/status.txt").unlink()
        self.request()
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 1)
        self.assertEqual(self.bridge.state["source"]["state"], "unavailable")
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("Inbox request 123-abcd", self.calls()[0][-1])
        self.assertEqual(self.bridge.state["events"][0]["type"], "relay.status")
        self.assertEqual(json.loads(events.read(self.bridge.file))["source"]["state"], "unavailable")

    def test_behind_recovery_never_rolls_back_persisted_height(self):
        self.write(status(8))
        self.bridge.poll()
        (self.net / "claude-1/status.txt").unlink()
        self.write(status(7, "merged", "closed"), "codex-1")
        self.bridge.poll()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 8)
        self.assertEqual(self.bridge.state["source"]["state"], "behind")
        self.write(status(9, "merged", "closed"), "codex-1")
        self.bridge.poll()
        self.bridge.deliver()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 9)
        self.assertEqual(len(self.calls()), 2)

    def test_genesis_disagreement_is_not_a_height_tiebreak(self):
        self.write(status(3))
        self.write(status(9, "merged", "closed"), "codex-1")
        (self.net / "codex-1/genesis.json").write_text('{"chain_id":"another-chain"}')
        self.bridge.poll()
        self.bridge.deliver()
        self.assertIsNone(self.bridge.state["snapshot"])
        self.assertEqual(self.bridge.state["source"]["reason"], "genesis mismatch")
        self.assertEqual(self.calls(), [])

    def test_equal_height_display_history_disagreement_is_explicit(self):
        self.write(status(3).replace("pool 0", "history claude-1\npool 0"))
        self.write(status(3).replace("pool 0", "history codex-1\npool 0"), "codex-1")
        self.bridge.poll()
        self.assertIsNone(self.bridge.state["snapshot"])
        self.assertEqual(self.bridge.state["source"]["state"], "conflict")

    def test_local_pool_and_backend_annotations_do_not_conflict(self):
        self.write(status(3) + "checkout wallet " + "b" * 40 + "\nLIMIT backend held\n")
        self.write(status(3).replace("pool 0", "pool 3") + "checkout wallet " + "c" * 40 + "\n", "codex-1")
        self.bridge.poll()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 3)
        self.assertEqual(self.bridge.state["source"]["state"], "available")

    def test_shared_view_anchor_and_reader_owned_snapshot_survive_fallback(self):
        self.bridge.poll()
        self.write(status(3, "merged", "closed"), "codex-1")
        output = self.net / ".cmux/view reader [one].txt"
        def view():
            result = subprocess.run([sys.executable, str(source), str(self.net), "--status-view",
                                     "--status-output", str(output)], check=True,
                                    text=True, capture_output=True, timeout=5)
            return json.loads(result.stdout)
        first = view()
        self.assertEqual(first["agent"], "codex-1")
        self.assertEqual(first["height"], 3)
        self.assertIn("height 3", output.read_text())
        (self.net / "codex-1/status.txt").unlink()
        self.write(status(2))
        behind = view()
        self.assertEqual(behind["state"], "behind")
        self.assertEqual(behind["height"], 3)
        self.assertIn("height 3", output.read_text())
        self.bridge.poll()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 1)
        self.write(status(4, "merged", "closed"))
        self.bridge.poll()
        self.assertEqual(self.bridge.state["snapshot"]["height"], 4)

    def test_status_age_must_be_positive_and_finite(self):
        for age in (0, -1, float("nan"), float("inf")):
            with self.assertRaises(ValueError):
                events.Bridge(self.net, str(self.cmux), status_max_age=age)

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
