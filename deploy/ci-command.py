#!/usr/bin/env python3
"""Generate a self-contained CI command from the operator's trusted checkout.

The manifest and verifier travel in the command, never in the bid's files.
A bid can't change the tests that judge it (test/ files already there), and
can't add an unproved assumption. It can change the deployment (deploy/,
scripts/host.sh, scripts/sandbox.sh): CI runs the operator's deployed copies
of those, never the bid's, so the change is code under test, attested like
any other, until the next deployment (an epoch, host.sh start) runs it, as it
runs the node's code the market merged (docs/PLAN.md).
"""
import collections
import hashlib
import json
from pathlib import Path
import re
import shlex
import sys


def assumptions(text):
    # Tokenize before looking for escapes: nested Rocq comments and quoted
    # strings cannot hide a token or cause examples in comments to be rejected.
    tokens = []
    i = 0
    depth = 0
    while i < len(text):
        if text.startswith('(*', i):
            depth += 1
            i += 2
        elif depth and text.startswith('*)', i):
            depth -= 1
            i += 2
        elif depth:
            i += 1
        elif text[i] == '"':
            start = i
            i += 1
            while i < len(text):
                if text[i] == '"':
                    i += 1
                    if i < len(text) and text[i] == '"':
                        i += 1
                        continue
                    break
                i += 1
            tokens.append(text[start:i])
        else:
            m = re.match(r"[\w']+|[^\s]", text[i:])
            if m:
                tokens.append(m[0])
                i += len(m[0])
            else:
                i += 1
    # Preserve each existing escape's complete statement, not just its count:
    # removing one assumption must not buy permission to introduce another.
    bad = {'admitted', 'admit', 'axiom', 'axioms', 'parameter', 'parameters',
           'hypothesis', 'hypotheses', 'variable', 'variables', 'context',
           'unk', 'unknown', 'err', 'error', 'cast', 'unsafe',
           'exact_no_check', 'vm_cast_no_check', 'native_cast_no_check', 'give_up'}
    result = collections.Counter()
    statement = []
    for token in tokens + ['.']:
        statement.append(token)
        if token == '.':
            if any(t.lower() in bad for t in statement):
                result[' '.join(statement)] += 1
            statement = []
    return result


def files(root):
    return [p for p in root.rglob('*')
            if not any(c in {'.git', '.soma-cache', 'pantheon-ocaml'} for c in p.relative_to(root).parts)
            and p.is_file()]


def deployment_file(name):
    return name.startswith('deploy/') or name in {'scripts/host.sh', 'scripts/sandbox.sh'}


def manifest(root):
    proofs, pinned, deployment = {}, {}, {}
    for p in files(root):
        name = p.relative_to(root).as_posix()
        if p.suffix in {'.soma', '.exp'}:
            proofs[name] = dict(assumptions(p.read_text()))
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        if name.startswith('test/'):
            pinned[name] = digest
        elif deployment_file(name):
            deployment[name] = digest
    return {'proofs': proofs, 'pinned': pinned, 'deployment': deployment}


def deployment_changes(root, baseline):
    # what the tree changes of the deployment: allowed, and said, since it
    # takes effect only when the operator deploys it
    old = baseline.get('deployment', {})
    new = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
           for p in files(root) if deployment_file(p.relative_to(root).as_posix())}
    return sorted(n for n in set(old) | set(new) if old.get(n) != new.get(n))


def added_tests(root, baseline):
    # test/*.sh the operator's checkout didn't have: a bid's own tests, which
    # CI runs after the command (docs/DOGFOOD-REPORT.md D-1). An existing one
    # is pinned, so a bid can't change it; tests a bid adds can't change CI.
    return sorted(p.relative_to(root).as_posix() for p in (root / 'test').glob('*.sh')
                  if p.is_file() and not p.is_symlink()
                  and p.relative_to(root).as_posix() not in baseline['pinned'])


def verify(root, baseline):
    for name, digest in baseline['pinned'].items():
        p = root / name
        if p.is_symlink() or not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != digest:
            raise ValueError('changed a test already there: ' + name + ' (a bid adds tests in new files; the ones there judge it)')
    for p in files(root):
        if p.suffix in {'.soma', '.exp'}:
            name = p.relative_to(root).as_posix()
            if p.is_symlink() or assumptions(p.read_text()) - collections.Counter(baseline['proofs'].get(name, {})):
                raise ValueError('new unproved assumption: ' + name)


if __name__ == '__main__':
    if sys.argv[1] == '--verify':
        try:
            baseline = json.loads(sys.argv[2])
            verify(Path.cwd(), baseline)
            for name in deployment_changes(Path.cwd(), baseline):
                print('CI: this tree changes ' + name + ' (deployment: CI ran the deployed copy; it takes effect once the operator deploys it)', file=sys.stderr)
            for name in added_tests(Path.cwd(), baseline):
                print(name)
        except (ValueError, OSError) as e:
            sys.exit('CI policy: ' + str(e))
    else:
        root = Path(sys.argv[1]).resolve()
        baseline = json.dumps(manifest(root), separators=(',', ':'))
        source = Path(__file__).read_text()
        # the policy check, then the command, then each test the bid adds,
        # each within PANTHEON_TEST_TIMEOUT seconds (default 600), in bash if
        # its first line asks for it
        # (the list goes through a file: a here-document inside $(...) trips
        # bash 3.2 when it holds a case pattern)
        print('pantheon_added_file=${TMPDIR:-/tmp}/pantheon-added.$$\n'
              'python3 - --verify ' + shlex.quote(baseline) + " > \"$pantheon_added_file\" <<'PANTHEON_CI_POLICY'\n" + source +
              '\nPANTHEON_CI_POLICY\npolicy_status=$?; [ "$policy_status" -eq 0 ] || exit "$policy_status"\n'
              'pantheon_added=$(cat "$pantheon_added_file"); rm -f "$pantheon_added_file"\n'
              '{\n' + sys.argv[2] + '\n} && for pantheon_test in $pantheon_added; do\n'
              '  echo "CI: $pantheon_test (this tree adds it)"\n'
              '  case $(head -n 1 "$pantheon_test") in \'#!\'*bash*) pantheon_sh=bash ;; *) pantheon_sh=sh ;; esac\n'
              '  timeout "${PANTHEON_TEST_TIMEOUT:-600}" "$pantheon_sh" "$pantheon_test" || { s=$?; echo "CI: $pantheon_test failed (exit $s)"; exit $s; }\n'
              'done')
