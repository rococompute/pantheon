#!/usr/bin/env python3
"""Exercise the shared plan renderer against overlapping calculator tasks."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
AWK = re.search(r"^ITEMS_AWK='(.*?)^}'$", (ROOT / 'integrations/cmux/pantheon-cmux').read_text(), re.M | re.S)[1] + '}'
SUB = 'Add a `sub` command, with a new test file tests/test_sub.sh.'
MUL = 'Add a `mul` command, with a new test file tests/test_mul.sh.'
# The canceled run put both commands in each task, despite assigning one step.
TASK_SUB = (f"Operator goal: ‘1. {SUB}’ Direction: extend calc.sh with subtraction, "
            "then multiplication in a separate task, preserving existing behavior. "
            "Useful next step: implement `sub` and add tests/test_sub.sh. "
            "Remaining work: finish any subtraction gaps, then add `mul` and "
            "tests/test_mul.sh as the separate second task.")
TASK_MUL = (f"Operator goal: '2. {MUL}' Why this one: step 1 (sub) is merged, "
            "with tests/test_sub.sh in the repo. Direction: calc.sh supports add, sub "
            "and mul. If usage changes, update tests/test_sub.sh's expectation.")


class PlanItems(unittest.TestCase):
    def render(self, tasks, bids, items='goal', goal=None):
        if goal is None:
            goal = f'1. {SUB}\n2. {MUL}\n' if items == 'goal' else SUB + '\n' + MUL + '\n'
        with tempfile.TemporaryDirectory() as tmp:
            status = Path(tmp) / 'status'
            source = Path(tmp) / 'goal'
            status.write_text(''.join(f'task {i} [{state}] calc: {text}\n' for i, state, text in tasks)
                              + ''.join(f'bid {i} [{state}] task {task} by codex\n' for i, state, task in bids))
            source.write_text(goal)
            return subprocess.check_output(['awk', '-v', 'items=' + items, AWK, str(status), str(source)], text=True)

    def assert_icons(self, output, sub, mul):
        self.assertIn(sub + ' ' + SUB, output)
        self.assertIn(mul + ' ' + MUL, output)

    def test_subtraction_pending_does_not_start_multiplication(self):
        self.assert_icons(self.render([(1, 'open', TASK_SUB)], [(1, 'pending', 1)]), '🌱', '🫘')

    def test_subtraction_merge_is_progress_until_closed(self):
        self.assert_icons(self.render([(1, 'open', TASK_SUB)], [(1, 'merged', 1)]), '🪴', '🫘')

    def test_multiplication_pending_does_not_reopen_subtraction(self):
        self.assert_icons(self.render([(1, 'closed', TASK_SUB), (2, 'open', TASK_MUL)],
                                     [(1, 'merged', 1), (2, 'pending', 2)]), '🌳', '🌱')

    def test_multiplication_merge_does_not_change_closed_subtraction(self):
        self.assert_icons(self.render([(1, 'closed', TASK_SUB), (2, 'open', TASK_MUL)],
                                     [(1, 'merged', 1), (2, 'merged', 2)]), '🌳', '🪴')

    def test_both_closed(self):
        self.assert_icons(self.render([(1, 'closed', TASK_SUB), (2, 'closed', TASK_MUL)],
                                     [(1, 'merged', 1), (2, 'merged', 2)]), '🌳', '🌳')

    def test_ambiguous_task_does_not_assign_itself_to_both_goals(self):
        self.assert_icons(self.render([(1, 'open', SUB + ' Also: ' + MUL)], [(1, 'pending', 1)]), '🫘', '🫘')

    def test_paraphrase_requires_the_goal_code_name(self):
        output = self.render([(1, 'open', 'Add a sub command with a new test file.')], [(1, 'pending', 1)],
                             goal='1. Add a `mul` command with a new test file.\n')
        self.assertIn('🫘 Add a `mul`', output)

    def test_cleared_and_rejected_bids_are_not_working(self):
        self.assert_icons(self.render([(1, 'open', TASK_SUB)], [(1, 'cleared', 1), (2, 'rejected', 1)]), '🫘', '🫘')

    def test_explicit_step_beats_background_references(self):
        output = self.render([(1, 'open', 'Goal step 2: implement multiplication. ' + SUB)], [(1, 'pending', 1)])
        self.assert_icons(output, '🫘', '🌱')

    def test_plan_marks_remain_authoritative(self):
        output = self.render([(1, 'closed', TASK_SUB)], [(1, 'merged', 1)], items='plan')
        self.assertIn('<summary>🪴 ' + SUB + '</summary>', output)
        self.assertIn('<summary>🫘 ' + MUL + '</summary>', output)


if __name__ == '__main__':
    unittest.main()
