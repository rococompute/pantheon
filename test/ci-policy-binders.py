#!/usr/bin/env python3
"""Scope-sensitive regression probes against the actual embedded CI policy."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('ci_command', ROOT / 'deploy/ci-command.py')
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)

POSITIVE = [
    'Definition f (cast : nat) := cast.',
    'Definition f (unknown err unk : nat) := unknown + err + unk.',
    'Definition f {cast : nat} (x : nat) := cast + x.',
    'Definition f (cast : nat) (x : cast = cast) := x.',
    'Definition f (cast : nat) : cast = cast := eq_refl.',
    '#[local] Definition f (cast : nat) := cast.',
    'Definition f (CAST : nat) := CAST.',
    'Definition f (admit : nat) := 1.',
    'Lemma f (cast : nat) : cast = cast. Proof. reflexivity. Qed.',
]
NEGATIVE = [
    'Definition f (cast : nat) := Corelib.Gradual.Gradual.cast nat nat cast.',
    'Definition f (cast : nat) := @Corelib.Gradual.Gradual.cast nat nat cast.',
    'Definition f (unk : nat) := Corelib.Gradual.Gradual.unknown nat.',
    'Definition f (cast : nat) := cast. Definition g := cast nat nat 1.',
    'Definition f (cast : cast nat Type 1) := cast.',
    'Definition f (x : cast nat Type 1) (cast : nat) := cast.',
    'Definition f (CAST : nat) := cast nat nat 1.',
    'Definition f (admit : nat) : False := ltac:(admit).',
    'Definition f (exact_no_check : nat) : False := ltac:(exact_no_check I).',
    'Definition f (cast : nat) := cast. Conjecture hole : False.',
    'Definition f (cast : nat) := cast. Definition g := err nat.',
    'Definition f (cast : nat) := cast. Definition g := unk.',
    'Definition f := ((fun cast : nat => cast) 1, cast nat nat 1).',
    'Definition f := let cast := cast nat nat 1 in cast.',
    'Definition f (x := cast nat nat 1) := x.',
    'Definition f (cast : nat) := cast. Definition g := unknown nat.',
    'Definition f (unknown : unknown Type) := unknown.',
    'Definition f (cast : nat) := Corelib.Gradual.Gradual . cast nat nat cast.',
    'Definition f (cast : nat] := cast nat nat 1.',
    'Definition f (cast : nat) := cast. Lemma g : False. Admitted.',
    'Fixpoint f (cast : nat) := cast with g (x : nat) := cast nat nat x.',
    'Inductive f (cast : nat) := mk_f : f cast with g := mk_g : cast nat Type 1.',
    'Definition f (cast : nat) := cast where "foo" := (cast nat nat 1).',
]


class ScopedPolicy(unittest.TestCase):
    def test_explicit_declaration_parameters(self):
        for source in POSITIVE:
            with self.subTest(source=source):
                self.assertFalse(POLICY.assumptions(source))

    def test_primitive_references_do_not_escape_via_shadowing(self):
        for source in NEGATIVE:
            with self.subTest(source=source):
                self.assertTrue(POLICY.assumptions(source))

    @unittest.skipUnless(os.environ.get('SOMA'), 'set SOMA for real compiler evidence')
    def test_semantic_escape_references(self):
        sources = [
            ('Definition f (cast : nat) := Corelib.Gradual.Gradual.cast nat nat cast.',
             'Corelib.Gradual.Gradual.cast'),
            ('Definition f (cast : nat) := cast. Definition g := cast nat nat 1.',
             'Corelib.Gradual.Gradual.cast'),
            ('Definition f := ((fun cast : nat => cast) 1, cast nat nat 1).',
             'Corelib.Gradual.Gradual.cast'),
            ('Definition f := let cast := cast nat nat 1 in cast.',
             'Corelib.Gradual.Gradual.cast'),
            ('Fixpoint f (cast : nat) : nat := cast with g (x : nat) : nat := cast nat nat x.',
             'Corelib.Gradual.Gradual.cast'),
            ('Conjecture hole : False.', 'fixture.hole'),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'fixture.soma'
            for source, expected in sources:
                with self.subTest(source=source):
                    path.write_text(source + '\n')
                    checked = subprocess.run([os.environ['SOMA'], 'hash', str(path)],
                                             capture_output=True, text=True,
                                             env=dict(os.environ, SOMA_HASH_FIELDS='1'))
                    self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                    assumptions = {name for line in checked.stdout.splitlines()
                                   for name in line.split('\t')[4:]}
                    self.assertIn(expected, assumptions)
                    self.assertTrue(POLICY.assumptions(source))

    def test_real_generated_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            head = Path(tmp) / 'head'
            head.mkdir()
            (head / 'main.soma').write_text('Definition original := 1.\n')
            command = subprocess.check_output([
                'python3', str(ROOT / 'deploy/ci-command.py'), str(head), 'true'], text=True)
            bid = Path(tmp) / 'bid'
            shutil.copytree(head, bid)
            for accepted, sources in ((True, POSITIVE), (False, NEGATIVE)):
                for source in sources:
                    with self.subTest(source=source):
                        (bid / 'main.soma').write_text(source + '\n')
                        result = subprocess.run(['sh', '-c', command], cwd=bid,
                                                capture_output=True, text=True)
                        self.assertEqual(result.returncode == 0, accepted,
                                         result.stdout + result.stderr)
                        if not accepted:
                            self.assertIn('CI policy: new unproved assumption:', result.stderr)


if __name__ == '__main__':
    unittest.main()
