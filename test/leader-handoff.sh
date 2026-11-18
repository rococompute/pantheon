#!/bin/sh
# Real nodes: CI finishes multiple terms late, then a node replays its journal.
set -eu
cd "$(dirname "$0")/.."
python3 - "$PWD/main.exe" <<'PY'
import json
import os
from pathlib import Path
import random
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='pantheon-leader-handoff-') as tmp:
    root = Path(tmp)
    repo = root/'source'
    repo.mkdir()
    (repo/'.plan').write_text('Create a file reporting progress.\n')
    (repo/'value').write_text('initial\n')
    def git(where, *args):
        return subprocess.check_output(['git', '-C', str(where), *args], text=True, stderr=subprocess.DEVNULL).strip()
    subprocess.run(['git', 'init', '-q', str(repo)], check=True)
    git(repo, 'add', '.')
    git(repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'base')
    for _ in range(100):
        sockets = []
        base = random.randrange(30000, 50000)
        try:
            for port in range(base, base+4):
                s = socket.socket()
                sockets.append(s)
                s.bind(('127.0.0.1', port))
            break
        except OSError:
            for s in sockets: s.close()
    else:
        raise AssertionError('no test ports available')
    net = root/'net'
    try:
        subprocess.run([binary, 'init', str(net), '--repo', 'r='+str(repo), '--base-port', str(base),
                        '--block-ms', '100', '--param', 'term_blocks=10', '--param', 'stall_blocks=10',
                        '--param', 'reveal_window=2', '--param', 'fallback_blocks=2',
                        '--param', 'attest_window=100', '--param', 'task_blocks=1000'],
                       check=True, stdout=subprocess.DEVNULL)
    finally:
        for s in sockets: s.close()
    goal = root/'goal'
    goal.write_text('Create a file reporting progress.\n')
    runner = root/'runner'
    runner.write_text('#!/bin/sh\nsleep 9\ncd "$2" || exit 3\nexec sh -c "$3"\n')
    runner.chmod(0o755)
    agents = ['claude', 'codex', 'grok', 'muse']
    processes, logs = {}, {}
    def start(a):
        if a not in logs:
            logs[a] = (root/(a+'.log')).open('a')
        processes[a] = subprocess.Popen([binary, 'node', str(net/a), '--backend', 'scripted',
            '--goal', str(goal), '--bid-window', '1', '--listen', '127.0.0.1',
            '--ci', 'echo CHECK_TIMING passed', '--ci-sandbox', str(runner)],
            stdout=logs[a], stderr=subprocess.STDOUT, start_new_session=True)
    def stop(a):
        p = processes[a]
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
    def entries(a):
        try:
            return [json.loads(line) for line in git(net/a/'leader-chain.git',
                'log', '--reverse', '--format=%s', 'leader-chain').splitlines()]
        except subprocess.CalledProcessError:
            return []
    try:
        for a in agents: start(a)
        deadline = time.monotonic()+60
        late = None
        while time.monotonic() < deadline:
            for a in agents:
                for e in entries(a):
                    origin = re.fullmatch(r'mcheck/term/(\d+)/request/\d+', e['origin'])
                    if e['kind']=='check-pass' and origin and int(e['term']) >= int(origin[1])+2:
                        late = e
                        break
                if late: break
            if late: break
            time.sleep(.25)
        assert late, 'no CI result recorded across two leader changes'
        author = late['author']
        source = net/author/'repos/r'
        assert git(source, 'rev-parse', late['commit']+'^{tree}') == late['tree']
        assert git(source, 'rev-parse', late['commit']+'^^{tree}') == late['base_tree']
        assert 'CHECK_TIMING' in late['info']
        info = json.loads(late['info'])
        assert info['base_commit'] == git(source, 'rev-parse', late['commit']+'^')
        assert len(info['check_key']) == 64
        deadline = time.monotonic()+70
        while time.monotonic() < deadline:
            texts = [(root/(a+'.log')).read_text() for a in agents]
            if any('reusing this node' in text for text in texts) and any('merged bid' in text for text in texts):
                break
            time.sleep(.25)
        else:
            raise AssertionError('returning leaders did not reuse their checks to make progress')
        prefix = entries(author)
        stop(author)
        restart_offset = (root/(author+'.log')).stat().st_size
        start(author)
        deadline = time.monotonic()+25
        replayed = False
        while time.monotonic() < deadline:
            current = entries(author)
            if len(current) >= len(prefix) and processes[author].poll() is None:
                # Give the replacement process time to replay, rather than
                # accepting the old Git files before startup has touched them.
                text = (root/(author+'.log')).read_text()[restart_offset:]
                if 'replayed ' in text:
                    replayed = True
                    break
            time.sleep(.25)
        assert replayed, 'replacement node did not finish replay'
        assert processes[author].poll() is None, (root/(author+'.log')).read_text()[-2000:]
        assert entries(author)[:len(prefix)] == prefix
        for a in agents:
            es = entries(a)
            for previous, current in zip(es, es[1:]):
                assert current['parent'] == previous['hash']
            common = min(len(es), len(prefix))
            assert es[:common] == prefix[:common]
        print('PASS multi-term CI handoff, verified local reuse, accepted progress and restart replay')
    except BaseException:
        for a in agents:
            if a in logs:
                logs[a].flush()
                print(a+':\n'+(root/(a+'.log')).read_text()[-2500:], file=sys.stderr)
        raise
    finally:
        for a in processes: stop(a)
        for log in logs.values(): log.close()
PY
