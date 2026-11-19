#!/usr/bin/env python3
"""Regression probes for the deployed verifier, not a Soma parser/model."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('ci_command', ROOT / 'deploy/ci-command.py')
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class AssumptionPolicy(unittest.TestCase):
    def test_ordinary_names_are_not_assumptions(self):
        for name in ('error', 'unsafe', 'context', 'variable', 'parameter', 'cast'):
            for source in (f'Definition {name} := 1.', f'{name} := 1.'):
                with self.subTest(source=source):
                    self.assertFalse(POLICY.assumptions(source))
        self.assertFalse(POLICY.assumptions('Definition f (context variable : nat) := context + variable.'))
        self.assertFalse(POLICY.assumptions('Definition f (error unsafe : nat) := error + unsafe.'))

    def test_declarations_and_actual_escapes_still_count(self):
        for source in (
            'Conjecture hole : False.', 'Global Polymorphic Conjectures hole : False.',
            '#[local] Axiom hole : False.', 'Time Axiom hole : False.',
            'Timeout 1 Axiom hole : False.', 'Redirect "note" Axiom hole : False.',
            'Variable x : nat.', 'Context (x : nat).',
            'Lemma hole : False. Admitted.', 'Lemma hole : False. Proof. admit. Qed.',
            'Definition hole : False := unk.', 'Definition hole : False := unknown False.',
            'Definition hole : False := err False.', 'Definition x := cast nat nat 1.',
            'Definition x := ltac:(exact_no_check I).',
            'Definition error : False := unk.',
        ):
            with self.subTest(source=source):
                self.assertTrue(POLICY.assumptions(source))

    def test_comments_strings_and_baseline_statement_identity(self):
        self.assertFalse(POLICY.assumptions('Definition error := "Axiom (* unk *)". (* Axiom (* nested *) hole *)'))
        self.assertNotEqual(POLICY.assumptions('old := unk.'), POLICY.assumptions('new := unk.'))

    def test_generated_command_accepts_ordinary_definition(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            head = root / 'head'
            head.mkdir()
            (head / 'main.soma').write_text('Definition ok := 1.\n')
            generated = subprocess.check_output(['python3', str(ROOT / 'deploy/ci-command.py'), str(head), 'true'], text=True)
            bid = root / 'bid'
            shutil.copytree(head, bid)
            (bid / 'main.soma').write_text('Definition ok := 1.\nDefinition error := 1.\n')
            result = subprocess.run(['sh', '-c', generated], cwd=bid, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
