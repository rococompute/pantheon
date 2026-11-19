#!/usr/bin/env python3
"""Exercise actual nft output verdicts in a disposable Linux network namespace."""
import importlib.util,json,os
from pathlib import Path
import shutil,subprocess,sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent.parent
if sys.platform!='linux' or os.geteuid()!=0:
    sys.exit('Requires Linux root, nft, ip, setpriv and unshare; never alters the host namespace.')
if '--inside' not in sys.argv:
    subprocess.run(['unshare','-n','python3','-B',__file__,'--inside'],check=True)
    sys.exit(0)
spec=importlib.util.spec_from_file_location('firewall',ROOT/'deploy/sandbox/render-firewall.py')
policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
template=(ROOT/'deploy/sandbox/firewall.nft').read_text()
def call(*args,**kwargs):return subprocess.run(args,check=True,**kwargs)
call('ip','link','add','audit0','type','dummy')
call('ip','addr','add','198.51.100.2/24','dev','audit0')
call('ip','link','set','audit0','up')
def install(config):
    call('nft','-f','-',input=policy.render(config,template,'1001','1002'),text=True)
def count():
    data=json.loads(subprocess.check_output(['nft','-j','list','table','inet','pantheon']))
    total={'accept':0,'drop':0}
    for item in data['nftables']:
        if 'rule' not in item:continue
        expr=item['rule']['expr'];packets=sum(e.get('counter',{}).get('packets',0) for e in expr)
        for verdict in total:
            if any(verdict in e for e in expr):total[verdict]+=packets
    return total
code='import socket,sys;s=socket.socket();s.setblocking(False);s.connect_ex((sys.argv[1],int(sys.argv[2])));s.close()'
def send(uid,address,port):
    call('setpriv','--reuid='+str(uid),'--regid='+str(uid),'--clear-groups','python3','-c',code,address,str(port))
install({'mode':'restricted','allow':[{'cidr':'198.51.100.10/32','tcp':[443]}]})
send(1001,'198.51.100.10',443)
assert count()['accept']>=1,count()
before=count()['drop'];send(1001,'198.51.100.11',443)
assert count()['drop']>before,count()
before=count()['drop'];send(1001,'198.51.100.10',80)
assert count()['drop']>before,count()
before=count()['drop'];send(1002,'198.51.100.11',443)
assert count()['drop']==before,count()
install({'mode':'restricted','allow':[]})
send(1001,'198.51.100.10',443)
assert count()['drop']>=1,count()
install({'mode':'public'})
send(1001,'198.51.100.11',443)
assert count()['drop']==0,count()
print('PASS actual nft: allowed node destination/port, denied unlisted destination/port, bidder compatibility, empty-list default-deny, public compatibility')
