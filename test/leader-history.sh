#!/bin/sh
# Real Git refs survive temporary checkouts, replay and a second replica.
set -eu
cd "$(dirname "$0")/.."
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
mkdir "$t/one" "$t/two"
for home in "$t/one" "$t/two" "$t/one"; do
  timeout 300 soma run test/leader_git.soma -- "$home" > "$t/out" 2> "$t/log" || { cat "$t/log" "$t/out"; exit 1; }
  cat "$t/out"
  grep -q '^ok journal append' "$t/out"
done
python3 - "$t" "$PWD/main.exe" <<'PY'
import json
from pathlib import Path
import shutil
import subprocess
import sys

root, binary = Path(sys.argv[1]), sys.argv[2]
def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()

one, two = root/'one/leader-chain.git', root/'two/leader-chain.git'
tip = git(one, 'rev-parse', 'refs/heads/leader-chain')
assert tip == git(two, 'rev-parse', 'refs/heads/leader-chain')
assert git(one, 'rev-list', '--count', 'refs/heads/leader-chain') == '2'
entries = [json.loads(line) for line in subprocess.check_output(
    [binary, 'leader-chain', str(root/'one')], text=True).splitlines() if line]
assert [e['sequence'] for e in entries] == ['1', '2']
assert entries[1]['parent'] == entries[0]['hash']
assert entries[1]['term'] == '4'

repo = root/'repo'
subprocess.run(['git', 'init', '-q', str(repo)], check=True)
git(repo, 'config', 'user.name', 'Test')
git(repo, 'config', 'user.email', 'test@example.invalid')
(repo/'value').write_text('old\n')
git(repo, 'add', '.')
git(repo, 'commit', '-qm', 'base')
base = git(repo, 'rev-parse', 'HEAD')
head = git(repo, 'rev-parse', 'HEAD^{tree}')
edits = root/'edits.json'
edits.write_text(json.dumps(['value', 'old\n', 'new\n']))
def check(out):
    return json.loads(subprocess.check_output(
        [binary, 'check', str(repo), head, str(edits), str(out), '--record'], text=True))
out = root/'candidate'
record = check(out)
assert record['base_commit'] == base
assert git(repo, 'rev-parse', record['commit']+'^{tree}') == record['tree']
assert git(repo, 'show', record['commit']+':value') == 'new'
ref = 'refs/pantheon/checks/'+base+'/'+record['tree']
assert git(repo, 'rev-parse', ref) == record['commit']
assert git(repo, 'rev-parse', 'HEAD') == base
shutil.rmtree(out)
git(repo, 'gc', '--prune=now')
assert git(repo, 'show', record['commit']+':value') == 'new'
assert check(root/'second-candidate') == record
assert git(repo, 'rev-parse', ref) == record['commit']
home = root/'one'
(home/'repos').mkdir()
shutil.copytree(repo, home/'repos/r')
subprocess.run([binary, 'leader-note', str(home), 'r', record['commit'],
                'Reproduction and remaining work'], check=True, stdout=subprocess.DEVNULL)
queued = json.loads(next((home/'inbox').glob('*.json')).read_text())
assert queued[:6] == ['leader-note', 'note', 'r', '0', record['tree'], '']
assert queued[6] == record['commit']
print('PASS deterministic journal replicas, immutable candidate refs and checkout cleanup')
PY
