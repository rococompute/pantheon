#!/usr/bin/env python3
"""Exercise installer compatibility failure before fetch/build and bidder tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallTools(unittest.TestCase):
    def test_compatible_checker_and_old_command(self):
        with tempfile.TemporaryDirectory(prefix='pantheon install ') as tmp:
            root = Path(tmp)
            checkout = root / 'checkout'
            (checkout / 'runtime').mkdir(parents=True)
            shutil.copy2(ROOT / 'install.sh', checkout / 'install.sh')
            (checkout / 'main.soma').write_text('main := 0.\n')
            (checkout / 'runtime/node_shell.soma').write_text('')
            bindir = root / 'bin'
            bindir.mkdir()
            soma = bindir / 'soma'
            soma.write_text('#!' + sys.executable + '\n'
                            'import os, pathlib, sys\n'
                            'if sys.argv[1] == "help":\n'
                            ' print("build run" if os.getenv("OLD_SOMA") else "check build test run")\n'
                            'elif sys.argv[1] == "check":\n'
                            ' assert "Any" in pathlib.Path(sys.argv[2]).read_text()\n'
                            'elif sys.argv[1] == "build":\n'
                            ' p = pathlib.Path("main.exe"); p.write_text("#!/bin/sh\\necho pantheon init\\n"); p.chmod(0o755)\n'
                            'else: sys.exit(2)\n')
            soma.chmod(0o755)
            env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'],
                       PANTHEON_BIN=str(root / 'installed'))
            refused = subprocess.run(['sh', str(checkout / 'install.sh')],
                                     env=dict(env, OLD_SOMA='1'), text=True, capture_output=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn('not a compatible gradual Soma build', refused.stderr)
            self.assertFalse((checkout / 'main.exe').exists())
            accepted = subprocess.run(['sh', str(checkout / 'install.sh')],
                                      env=env, text=True, capture_output=True)
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
            self.assertTrue((root / 'installed/pantheon').exists())

    def test_bidder_gets_repository_check_tools(self):
        # Capture actual vendor argv; no model service is invoked.
        with tempfile.TemporaryDirectory(prefix='pantheon bidder ') as tmp:
            root = Path(tmp)
            for model in ['claude', 'grok']:
                log = root / (model + '.json')
                cli = root / model
                cli.write_text('#!' + sys.executable + '\n'
                               'import json, os, pathlib, sys\n'
                               'pathlib.Path(os.environ["ARGV_LOG"]).write_text(json.dumps(sys.argv[1:]))\n'
                               'print("checked")\n')
                cli.chmod(0o755)
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                           BIDDER_MODEL=model, PANTHEON_WORKTREE=str(root), ARGV_LOG=str(log))
                result = subprocess.run(['sh', str(ROOT / 'scripts/bidder.sh')],
                                        input='Make a patch.\n', text=True, capture_output=True, env=env)
                # Later patch assembly may fail in this deliberately non-Git
                # fixture; permission arguments are captured before that.
                self.assertTrue(log.exists(), result.stdout + result.stderr)
                args = json.loads(log.read_text())
                for rule in ['Bash(soma check:*)', 'Bash(soma test:*)', 'Bash(./scripts/check:*)']:
                    self.assertIn(rule, args)


if __name__ == '__main__':
    unittest.main()
