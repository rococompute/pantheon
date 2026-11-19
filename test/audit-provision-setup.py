#!/usr/bin/env python3
"""Execute the actual provisioning block twice under a fixture root."""
import os
from pathlib import Path
import subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parent.parent
class Provision(unittest.TestCase):
    def test_build_lock_and_bidder_wrapper_are_idempotent(self):
        source=(ROOT/'deploy/sandbox/provision.sh').read_text()
        block=source.split('install -d -m 755 /var/lib/pantheon-build',1)[1].split('# swap,',1)[0]
        block='install -d -m 755 /var/lib/pantheon-build'+block
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'etc/pantheon').mkdir(parents=True)
            block=block.replace('/var/lib/pantheon-build',str(root/'build'))
            block=block.replace('/usr/local/lib/pantheon/bidder-bin',str(root/'bidder-bin'))
            block=block.replace('/etc/pantheon/',str(root/'etc/pantheon')+'/')
            env=dict(os.environ,here=str(ROOT/'deploy/sandbox'))
            subprocess.run(['sh','-eu','-c',block],env=env,check=True)
            lock=root/'build/lock';inode=lock.stat().st_ino
            self.assertEqual(lock.stat().st_mode&0o777,0o644)
            self.assertEqual((root/'bidder-bin/soma').read_bytes(),(ROOT/'deploy/sandbox/soma-locked').read_bytes())
            (root/'etc/pantheon/ci-memory').write_text('2g\n')
            subprocess.run(['sh','-eu','-c',block],env=env,check=True)
            self.assertEqual(lock.stat().st_ino,inode)
            self.assertEqual((root/'etc/pantheon/ci-memory').read_text(),'2g\n')
            self.assertIn('"$here/deploy/sandbox/soma-locked"', (ROOT/'scripts/sandbox.sh').read_text())
if __name__=='__main__':unittest.main()
