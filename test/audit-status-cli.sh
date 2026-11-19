#!/bin/sh
# Actual CLI file routing, no running market or network.
set -eu
cd "$(dirname "$0")/.."
PANTHEON=${PANTHEON:-"$PWD/main.exe"}
export PANTHEON
python3 - <<'PY'
import json, os, pathlib, subprocess, tempfile
binary = str(pathlib.Path(os.environ['PANTHEON']).resolve())
with tempfile.TemporaryDirectory(prefix='pantheon-status-cli-') as tmp:
    home = pathlib.Path(tmp)/'home with spaces'
    home.mkdir()
    text = 'height 11  term 1  leader leader\nlegacy text stays exact\n'
    data = {'schema':'pantheon-status-1','scope':'market','height':11,'pending_merge':{'bid':1,'votes':[{'voter':'agent-a','approve':False,'reason':'missing "key"\ncheck'}]}}
    snapshot = json.dumps(data, separators=(',', ':'))+'\n'
    (home/'status.txt').write_text(text)
    (home/'status.json').write_text(snapshot)
    def run(args):
        return subprocess.run([binary,*args], text=True,capture_output=True,timeout=15)
    r = run(['status',str(home)])
    assert r.returncode == 0 and r.stdout == text, (r.returncode,r.stdout,r.stderr)
    print('ok default status preserves existing text bytes')
    for args in [['status',str(home),'--json'], ['status','--json',str(home)]]:
        r=run(args)
        assert r.returncode==0 and r.stdout==snapshot and json.loads(r.stdout)==data, (args,r.returncode,r.stdout,r.stderr)
        print('ok JSON flag reads separate structured snapshot '+repr(args))
    (home/'status.json').write_text('[]\n')
    r=run(['status',str(home),'--json'])
    assert r.returncode != 0 and 'not a valid market status object' in r.stderr, (r.returncode,r.stdout,r.stderr)
    print('ok non-object JSON status is refused')
    (home/'status.json').unlink()
    r=run(['status',str(home),'--json'])
    assert r.returncode != 0 and 'no JSON status' in r.stderr, (r.returncode,r.stdout,r.stderr)
    print('ok missing JSON status explains upgrade/start requirement')
    r=run(['status',str(home)])
    assert r.returncode == 0 and r.stdout==text, (r.returncode,r.stdout,r.stderr)
    print('ok legacy text status works without JSON snapshot')
print('PASS CLI status file routing')
PY
