#!/usr/bin/env python3
import importlib.util,json
from pathlib import Path
import subprocess,sys,tempfile,unittest
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('firewall',ROOT/'deploy/sandbox/render-firewall.py')
policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
TEMPLATE=(ROOT/'deploy/sandbox/firewall.nft').read_text()
class Firewall(unittest.TestCase):
    def test_compatibility_and_restricted_policy(self):
        public=policy.render({'mode':'public'},TEMPLATE,'1001','1002')
        self.assertNotIn('meta skuid 1001 counter drop',public)
        restricted=policy.render({'mode':'restricted','allow':[{'cidr':'198.51.100.10/32','tcp':[443,22]}]},TEMPLATE,'1001','1002')
        self.assertIn('ip daddr 198.51.100.10/32 tcp dport { 22, 443 } counter accept',restricted)
        self.assertIn('meta skuid 1001 counter drop',restricted)
        self.assertNotIn('meta skuid 1002 counter drop',restricted)
        self.assertIn('meta skuid 1001 counter drop',policy.render({'mode':'restricted'},TEMPLATE,'1001','1002'))
        self.assertLess(restricted.index('192.168.0.0/16'),restricted.index('198.51.100.10/32'))
    def test_invalid_configuration_is_refused(self):
        for config in [{'mode':'oops'},{'mode':'restricted','allow':'any'},
                       {'mode':'restricted','allow':[{'cidr':'1.2.3.4; accept','tcp':[443]}]},
                       {'mode':'restricted','allow':[{'cidr':'::1','tcp':[443]}]},
                       {'mode':'restricted','allow':[{'cidr':'1.2.3.4','tcp':[True]}]},
                       {'mode':'restricted','allow':[{'cidr':'1.2.3.4','tcp':[65536]}]}]:
            with self.subTest(config=config):
                with self.assertRaises((ValueError,TypeError)):policy.render(config,TEMPLATE,'1001','1002')
    def test_actual_nft_parser_when_requested(self):
        # An isolated Linux network namespace keeps the VM rules untouched.
        if '--kernel' not in sys.argv:self.skipTest('pass --kernel on Linux with root/nft/unshare')
        for mode in ['public','restricted']:
            rules=policy.render({'mode':mode,'allow':[{'cidr':'198.51.100.10/32','tcp':[443]}]},TEMPLATE,'1001','1002')
            subprocess.run(['unshare','-n','nft','-f','-'],input=rules,text=True,check=True)
if __name__=='__main__':
    args=[a for a in sys.argv if a!='--kernel']
    # Keep the marker visible to the method while unittest sees clean argv.
    unittest.main(argv=args)
