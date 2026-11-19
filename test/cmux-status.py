#!/usr/bin/env python3
"""Shared status selection drives real plan/title/history/readiness functions."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


repo = Path(__file__).resolve().parents[1]
source = Path(os.environ.get("PANTHEON_CMUX_SOURCE", repo / "integrations/cmux/pantheon-cmux"))


class TestStatusViews(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pantheon view [test] ")
        self.net = Path(self.temp.name) / "net"
        self.state = self.net / ".cmux"
        self.state.mkdir(parents=True)
        self.trees = {}
        for agent in ("claude-1", "codex-1"):
            home = self.net / agent
            home.mkdir()
            (home / "key.json").write_text("{}")
            (home / "genesis.json").write_text('{"chain_id":"test-chain"}')
            checkout = home / "repos/calc"
            checkout.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            self.trees[agent] = self.commit(agent, "the accepted plan\n")
        goal = self.state / "GOAL.md"
        goal.write_text("A calculator market.\n")
        (self.state / "goal").write_text(str(goal))
        text = source.read_text()
        sections = []
        for name in ("ITEMS_AWK", "GOAL_AWK", "BIDS_AWK"):
            sections.append(re.search(r"^" + name + r"='.*?^}'$", text, re.M | re.S)[0])
        for name in ("agents_of", "status_observe", "market_title", "render_plan", "market_finished", "note_leaders"):
            found = re.search(r"^" + name + r"\(\) \{\n.*?^}", text, re.M | re.S)
            if found:
                sections.append(found[0])
            else:
                self.assertEqual(name, "status_observe")  # Baseline reproducer.
        self.functions = self.state / "functions.sh"
        self.functions.write_text("\n".join(sections) +
                                  '\nsay() { printf "%s\\n" "$*"; }\nmux_plan_changed() { :; }\n')

    def tearDown(self):
        self.temp.cleanup()

    def commit(self, agent, plan):
        checkout = self.net / agent / "repos/calc"
        (checkout / ".plan").write_text(plan)
        subprocess.run(["git", "-C", str(checkout), "add", ".plan"], check=True)
        subprocess.run(["git", "-C", str(checkout), "-c", "user.name=Audit", "-c",
                        "user.email=audit@example.invalid", "-c", "commit.gpgsign=false",
                        "commit", "-qm", "plan"], check=True)
        return subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD^{tree}"], text=True).strip()

    def status(self, agent, height, finished=False):
        text = (f"height {height}  term 2  leader codex-1\nversion 1\n"
                f"history  claude-1 codex-1\nrepo calc {self.trees[agent]}\n"
                + ("finished: every agent found no more tasks\n" if finished else "") + "pool 0\n")
        (self.net / agent / "status.txt").write_text(text)

    def run_functions(self, command):
        env = dict(os.environ, NET=str(self.net), ST=str(self.state), here=str(repo), MUX_STATE=".cmux")
        return subprocess.run(["sh", "-c", 'set -eu; . "$1"; ' + command, "sh", str(self.functions)],
                              env=env, text=True, capture_output=True, timeout=15)

    def test_missing_first_node_falls_back_for_title_plan_history_and_finish(self):
        self.trees["codex-1"] = self.commit("codex-1", "the live node plan\n")
        self.status("codex-1", 4)
        title = self.run_functions("market_title")
        self.assertEqual(title.returncode, 0, title.stderr)
        self.assertEqual(title.stdout, "Market (codex-1 leader)")
        rendered = self.run_functions("render_plan; note_leaders; note_leaders")
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        plan = (self.state / "plan.md").read_text()
        self.assertIn("the live node plan", plan)
        self.assertNotIn("the accepted plan", plan)
        self.assertEqual(len((self.state / "leaders.log").read_text().splitlines()), 2)
        self.status("codex-1", 5, finished=True)
        self.assertEqual(self.run_functions("market_finished").returncode, 0)

    def test_plan_reads_the_observed_tree_instead_of_a_newer_head(self):
        self.status("claude-1", 1)
        self.commit("claude-1", "a newer unobserved plan\n")
        rendered = self.run_functions("render_plan")
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        plan = (self.state / "plan.md").read_text()
        self.assertIn("the accepted plan", plan)
        self.assertNotIn("a newer unobserved plan", plan)

    def test_conflicting_or_behind_views_cannot_finish_or_roll_back_the_view(self):
        self.status("claude-1", 4)
        self.assertEqual(self.run_functions("render_plan").returncode, 0)
        self.status("claude-1", 5, finished=True)
        self.status("codex-1", 5)
        rendered = self.run_functions("render_plan")
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertIn("Status observation: conflict", (self.state / "plan.md").read_text())
        self.assertNotEqual(self.run_functions("market_finished").returncode, 0)
        (self.net / "claude-1/status.txt").unlink()
        self.status("codex-1", 3)
        rendered = self.run_functions("render_plan; note_leaders")
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertIn("last accepted committed height 4", (self.state / "plan.md").read_text())


if __name__ == "__main__":
    unittest.main()
