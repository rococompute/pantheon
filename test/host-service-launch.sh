#!/bin/sh
# Render the real service provisioning twice without privileged operations.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
for pass in first repeat; do
  HOST_DRY="$t/dry" PANTHEON_HOST="$t/unused" AGENTS='claude codex muse' \
    VM_AGENTS=muse HOST_OPERATOR=alice BRANCH=master REMOTE= \
    PANTHEON_CI='printf "%s\n" "CI command" && true' \
    sh "$here/scripts/host.sh" services
  mkdir -p "$t/$pass"
  # Execute the emitted wrapper-writing operations, leaving root operations
  # untouched. These are the same printf commands deployed by services.
  python3 - "$t/dry/services.sh" "$t/$pass" <<'PY'
import pathlib, re, shlex, subprocess, sys
script = pathlib.Path(sys.argv[1]).read_text()
stage = pathlib.Path(sys.argv[2])
lines = re.findall(r'^printf .*?> "\$stage/(?:run|backend)-[^"]+"', script, re.M | re.S)
assert len(lines) == 6
subprocess.run(['sh', '-eu', '-c', 'stage=$1\n' + '\n'.join(lines), 'sh', str(stage)], check=True)
for agent in ('claude', 'codex', 'muse'):
    run = stage.joinpath('run-' + agent + '.sh').read_text()
    subprocess.run(['sh', '-n'], input=run, text=True, check=True)
    args = shlex.split(run.partition('\n')[2])
    i = args.index('--ci-repo')
    assert args[i + 1] == 'pantheon'
    assert 'CI command' in args[i + 2]
    assert args[i + 3] == '--ci-sandbox', args
    assert args[-2:] == ['--ci-memory', '3g'], args  # Soma in scope: its build peaks at 2.3 GB
    assert args[args.index('--backend') + 1] == 'cmd:/var/lib/pantheon/net/' + agent + '/backend.sh'
    backend = shlex.split(stage.joinpath('backend-' + agent + '.sh').read_text().splitlines()[1])
    expected = ['PANTHEON_INBOX=/var/lib/pantheon-inbox/' + agent,
                'PANTHEON_INBOX_GROUP=inbox-' + agent]
    if agent == 'muse':
        expected += ['INBOX_URL=http://192.168.5.2:8787']
    assert backend[:-2] == expected, backend
    assert backend[-2] == 'exec'
    assert backend[-1].endswith('/scripts/bidder-inbox.sh')
assert 'User=pantheon\n' in script
PY
done
for a in claude codex muse; do
  cmp "$t/first/run-$a.sh" "$t/repeat/run-$a.sh"
  cmp "$t/first/backend-$a.sh" "$t/repeat/backend-$a.sh"
done
echo PASS
