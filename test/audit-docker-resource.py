#!/usr/bin/env python3
"""Bounded Linux integration with a real daemon and production root wrapper.
Uses an already-present image only; never pulls or changes deployed files.
"""
import getpass,os
from pathlib import Path
import subprocess,sys,tempfile,uuid
ROOT=Path(__file__).resolve().parent.parent
if sys.platform!='linux' or os.geteuid()!=0:
    sys.exit('Requires Linux root and an existing Docker image; use sudo on a test machine.')
image=os.environ.get('AUDIT_CI_IMAGE','pantheon:dev')
def docker(*args,check=True):
    return subprocess.run(['/usr/bin/docker',*args],capture_output=True,text=True,check=check,timeout=30)
docker('image','inspect',image)
if docker('ps','-q','--filter','name=^/pantheon-ci-').stdout.strip():
    sys.exit('An existing Pantheon CI container is running; fixture refuses to interfere.')
nonce=uuid.uuid4().hex[:12]
old='pantheon-ci-'+nonce+'a';new='pantheon-ci-'+nonce+'b'
with tempfile.TemporaryDirectory(prefix='pantheon-check',dir='/tmp') as tmp:
    root=Path(tmp);root.chmod(0o755)
    cfg=root/'cfg';cfg.mkdir();(cfg/'ci-memory').write_text('64m\n');(cfg/'ci-lock-wait').write_text('0\n')
    (cfg/'ci-images').write_text(image+'\n');(root/'lock').touch()
    code=(ROOT/'deploy/sandbox/pantheon-docker').read_text()
    code=code.replace('/etc/pantheon/',str(cfg)+'/').replace('/var/lib/pantheon-build/lock',str(root/'lock'))
    wrapper=root/'wrapper';wrapper.write_text(code)
    env=dict(os.environ,SUDO_USER=getpass.getuser())
    def wrapped(*args):
        return subprocess.run(['sh',str(wrapper),*args],env=env,capture_output=True,text=True,timeout=30)
    args=['run','--rm','--name',new,'--network=none','--read-only','--tmpfs','/tmp:exec,size=64m',
          '--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=512','--memory=64m','--memory-swap=64m',
          '--user=65534:65534','-e','HOME=/tmp','-v',str(root)+':/work:ro','-w','/work',image,'sh','-c','echo CANNON_OK']
    try:
        docker('run','--rm','-d','--name',old,'--network=none','--memory=64m','--pids-limit=16',image,'sleep','60')
        p=wrapped('ps','-a','-q','--filter','name=^/'+old+'$')
        assert p.returncode==0 and p.stdout.strip(),(p.returncode,p.stdout,p.stderr)
        p=wrapped(*args)
        assert p.returncode==75 and 'still runs' in p.stderr,(p.returncode,p.stdout,p.stderr)
        assert not docker('ps','-a','-q','--filter','name=^/'+new+'$').stdout.strip()
        docker('rm','-f',old)
        p=wrapped(*args)
        assert p.returncode==0 and 'CANNON_OK' in p.stdout,(p.returncode,p.stdout,p.stderr)
        p=wrapped('ps','-a','-q','--filter','name=^/'+new+'$')
        assert p.returncode==0 and not p.stdout.strip(),(p.returncode,p.stdout,p.stderr)
        p=wrapped('ps','-a','-q','--filter','name=^/pantheon-ci-.*$')
        assert p.returncode==64,(p.returncode,p.stdout,p.stderr)
    finally:
        docker('rm','-f',old,check=False);docker('rm','-f',new,check=False)
print('PASS real Docker wrapper: exact metadata query, orphan-container budget barrier, resumed run after teardown, absent-container query and regex refusal')
