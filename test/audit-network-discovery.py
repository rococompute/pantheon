#!/usr/bin/env python3
"""Run the production launcher against alternate kernel route records."""
import json, os
from pathlib import Path
import subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parent.parent
class Network(unittest.TestCase):
    def test_interface_name_is_not_assumed_and_empty_address_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=root/'cfg';cfg.mkdir();(cfg/'ci').mkdir()
            for name,value in [('backend','scripted'),('ci-memory','3g'),('goal.txt','goal')]:
                (cfg/name).write_text(value+'\n')
            ip=root/'ip';ip.write_text('#!/bin/sh\nprintf "%s\\n" "$AUDIT_ROUTE"\n');ip.chmod(0o755)
            binary=root/'main';binary.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n');binary.chmod(0o755)
            source=(ROOT/'deploy/sandbox/node.sh').read_text().replace('/etc/pantheon/',str(cfg)+'/')
            source=source.replace('/home/pantheon/pantheon/main.exe',str(binary))
            script=root/'node.sh';script.write_text(source)
            env=dict(os.environ,PATH=str(root)+os.pathsep+os.environ['PATH'])
            for interface in ['enp0s1','ens3','eth0']:
                env['AUDIT_ROUTE']='1.1.1.1 via 192.0.2.1 dev '+interface+' src 192.0.2.9 uid 1000'
                p=subprocess.run(['sh',str(script)],env=env,capture_output=True,text=True)
                self.assertEqual(p.returncode,0,p.stderr)
                args=json.loads(p.stdout);self.assertEqual(args[args.index('--listen')+1],'192.0.2.9')
            env['AUDIT_ROUTE']='unreachable 1.1.1.1'
            p=subprocess.run(['sh',str(script)],env=env,capture_output=True,text=True)
            self.assertEqual(p.returncode,3,p.stdout+p.stderr)
            self.assertNotIn('node',p.stdout)
if __name__=='__main__':unittest.main()
