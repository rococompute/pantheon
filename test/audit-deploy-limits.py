#!/usr/bin/env python3
"""Run production wrappers with fixture-only absolute path remapping.
No deployed configuration, daemon or privileged mount is changed.
"""
import fcntl
import getpass
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parent.parent

@unittest.skipUnless(sys.platform.startswith('linux') and shutil.which('flock'), 'Linux flock/stat contracts')
class Limits(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='pantheon-check',dir='/tmp')
        self.root=Path(self.tmp.name)
        self.cfg=self.root/'etc';self.cfg.mkdir()
        (self.cfg/'ci-memory').write_text('3g\n')
        (self.cfg/'ci-images').write_text('ci:test\n')
        (self.cfg/'ci-lock-wait').write_text('0\n')
        self.lock=self.root/'lock';self.lock.touch()
        self.bin=self.root/'bin';self.bin.mkdir()
        docker=self.bin/'docker'
        docker.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$AUDIT_DOCKER_ARGS"\n')
        docker.chmod(0o755)
        soma=self.bin/'soma';soma.write_text('#!/bin/sh\necho soma-ran\n');soma.chmod(0o755)
        self.env=dict(os.environ,AUDIT_DOCKER_ARGS=str(self.root/'args'),SUDO_USER=getpass.getuser())
        self.scripts={}
        for name in ['pantheon-docker','soma-locked']:
            code=(ROOT/'deploy/sandbox'/name).read_text()
            code=code.replace('/etc/pantheon/',str(self.cfg)+'/').replace('/var/lib/pantheon-build/lock',str(self.lock))
            code=code.replace('/usr/bin/docker',str(docker)).replace('/home/pantheon/soma/_build/install/default/bin/soma',str(soma))
            path=self.root/name;path.write_text(code);self.scripts[name]=path
    def tearDown(self):self.tmp.cleanup()
    def docker(self,mem='3g',tmp='3g'):
        args=['run','--rm','--name','pantheon-ci-ab','--network=none','--read-only','--tmpfs','/tmp:exec,size='+tmp,
              '--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=512','--memory='+mem,'--memory-swap='+mem,
              '--user=65534:65534','-e','HOME=/tmp','-v',str(self.root)+':/work:ro','-w','/work','ci:test','sh','-c','true']
        return subprocess.run(['sh',str(self.scripts['pantheon-docker']),*args],env=self.env,capture_output=True,text=True)
    def test_budget_is_operator_owned(self):
        for mem,tmp in [('9999m','9999m'),('9g','3g'),('3g','9999m'),('0m','0m')]:
            with self.subTest(mem=mem,tmp=tmp):
                self.assertNotEqual(self.docker(mem,tmp).returncode,0)
                self.assertFalse((self.root/'args').exists())
        p=self.docker();self.assertEqual(p.returncode,0,p.stderr)
        args=(self.root/'args').read_text().splitlines()
        self.assertIn('--memory=3g',args);self.assertIn('/tmp:exec,size=3g',args)
    def test_missing_lock_fails_closed(self):
        self.lock.unlink()
        p=self.docker();self.assertNotEqual(p.returncode,0)
        self.assertFalse((self.root/'args').exists())
        p=subprocess.run(['sh',str(self.scripts['soma-locked']),'build','main.soma'],capture_output=True,text=True,env=self.env)
        self.assertEqual(p.returncode,3,p.stdout+p.stderr)
        self.assertNotIn('soma-ran',p.stdout)
    def test_contended_lock_wait_is_bounded(self):
        with self.lock.open() as stream:
            fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertEqual(self.docker().returncode,75)
            p=subprocess.run(['sh',str(self.scripts['soma-locked']),'build','main.soma'],capture_output=True,text=True,env=self.env,timeout=5)
            self.assertEqual(p.returncode,75,p.stdout+p.stderr)
            self.assertNotIn('soma-ran',p.stdout)
        p=subprocess.run(['sh',str(self.scripts['soma-locked']),'build','main.soma'],capture_output=True,text=True,env=self.env)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertIn('soma-ran',p.stdout)

class WholeBuildTimeout(unittest.TestCase):
    @unittest.skipUnless(shutil.which('timeout'),'GNU timeout required')
    def test_hung_initial_build_is_timed_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name,body in [('opam','exit 0'),('make','echo initial-build-started; sleep 30')]:
                p=root/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o755)
            env=dict(os.environ,PATH=str(root)+os.pathsep+os.environ['PATH'],SOMA_CI_TIMEOUT='1')
            p=subprocess.run(['sh',str(ROOT/'deploy/sandbox/soma-ci')],cwd=root,env=env,capture_output=True,text=True,timeout=5)
            self.assertEqual(p.returncode,124,p.stdout+p.stderr)
            # The initial make output is redirected by the original CI body.
            for value in ['0','901','999999999999999999','oops']:
                env['SOMA_CI_TIMEOUT']=value
                p=subprocess.run(['sh',str(ROOT/'deploy/sandbox/soma-ci')],cwd=root,env=env,capture_output=True,text=True,timeout=5)
                self.assertEqual(p.returncode,3,p.stdout+p.stderr)

if __name__=='__main__':unittest.main()
