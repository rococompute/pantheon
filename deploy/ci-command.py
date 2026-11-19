#!/usr/bin/env python3
"""Generate a self-contained CI command from the operator's trusted checkout.

The manifest and verifier travel in the command, never in the bid's files.
A bid can't change the tests that judge it (test/ files already there), and
rejects recognized new assumption declarations and explicit escape hatches.
This is a lexical guard, not a semantic audit of macros or dependencies.
It can change the deployment (deploy/,
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
            m = re.match(r"[\w']+(?:\.[\w']+)*|[^\s]", text[i:])
            if m:
                tokens.append(m[0])
                i += len(m[0])
            else:
                i += 1
    # Keep declarations separate from term/tactic uses: a definition named
    # `error`, `context` or `cast` does not introduce an assumption. This is
    # deliberately a lexical guard: aliases/macros need semantic auditing.
    declarations = {'admitted', 'axiom', 'axioms', 'conjecture', 'conjectures',
                    'parameter', 'parameters', 'hypothesis', 'hypotheses',
                    'variable', 'variables', 'context'}
    term_escapes = {'unk', 'unknown', 'err', 'cast'}
    tactic_escapes = {'admit', 'exact_no_check', 'vm_cast_no_check',
                      'native_cast_no_check', 'give_up'}
    escapes = term_escapes | tactic_escapes
    named = {'definition', 'abbreviation', 'example', 'lemma', 'theorem',
             'fact', 'remark', 'corollary', 'proposition', 'fixpoint',
             'cofixpoint', 'inductive', 'coinductive', 'record', 'class',
             'instance', 'let'}
    modifiers = {'local', 'global', 'polymorphic', 'monomorphic', 'program',
                 'cumulative', 'noncumulative', 'private', 'time', 'succeed', 'fail'}

    def command_start(statement):
        j = 0
        while j < len(statement):
            token = statement[j].lower()
            if token in modifiers:
                j += 1
            elif token in {'timeout', 'redirect'} and j + 1 < len(statement):
                j += 2
            elif statement[j:j + 2] == ['#', '[']:
                j += 2
                nesting = 1
                while j < len(statement) and nesting:
                    nesting += (statement[j] == '[') - (statement[j] == ']')
                    j += 1
            else:
                break
        return j

    def is_short_definition(statement, start):
        # Soma's usual `f (x : T) : U := body` has no leading Definition.
        # Require an actual top-level assignment: `unk : nat` is an ordinary
        # expression using a primitive, not a declaration named unk. Nested
        # binder/default/let assignments cannot establish a top-level name.
        if (not re.fullmatch(r"[^\W\d][\w']*", statement[start])
                or statement[start + 1:start + 2] not in [[':'], ['('], ['{']]):
            return False
        closing = {'(': ')', '{': '}', '[': ']'}
        stack = []
        lets = 0
        for j in range(start + 1, len(statement)):
            token = statement[j]
            if token in closing:
                stack.append(closing[token])
            elif token in {')', '}', ']'}:
                if not stack or stack.pop() != token:
                    return False
            elif not stack:
                if token == 'let':
                    lets += 1
                elif token == 'in' and lets:
                    lets -= 1
                elif not lets and statement[j:j + 2] == [':', '=']:
                    return True
        return False

    def is_escape(statement):
        start = command_start(statement)
        if start >= len(statement):
            return False
        short_definition = is_short_definition(statement, start)
        if not short_definition and statement[start].lower() in declarations:
            return True
        # Do not confuse a declared identifier with a use of the primitive.
        # For ordinary definitions both the Rocq spelling and Soma's short
        # `name := ...` / `name : type := ...` spelling name one identifier.
        binding = None
        if short_definition:
            binding = start
        elif statement[start].lower() in named:
            binding = start + 1
        # Recognize only explicit, typed declaration parameter groups. A
        # parameter enters scope after its own complete type, not in that type
        # or in an earlier group. Scope ends with this statement. In particular
        # a local fun/let binder does not establish a file-wide safe name.
        # Unsupported binder syntax stays conservatively guarded; this is not
        # a Rocq term parser or a semantic no-new-axioms check.
        parameter_names = set()
        enters_scope = {}
        j = binding + 1 if binding is not None else len(statement)
        # Mutual declarations/where-notations have several distinct scopes.
        # Do not infer any parameter scope for those commands.
        parameter_commands = {'definition', 'abbreviation', 'example', 'lemma',
                              'theorem', 'fact', 'remark', 'corollary', 'proposition'}
        if ((short_definition or statement[start].lower() in parameter_commands)
                and not any(token.lower() in {'with', 'where'} for token in statement)):
            closing = {'(': ')', '{': '}', '[': ']'}
            while j < len(statement) and statement[j] in {'(', '{'}:
                begin = j
                stack = [closing[statement[j]]]
                j += 1
                while j < len(statement) and stack:
                    if statement[j] in closing:
                        stack.append(closing[statement[j]])
                    elif statement[j] in {')', '}', ']'}:
                        if statement[j] != stack.pop():
                            break
                    j += 1
                if stack or j > len(statement) or statement[j - 1] != closing[statement[begin]]:
                    break
                end = j - 1
                colon = begin + 1
                while colon < end and re.fullmatch(r"[^\W\d][\w']*", statement[colon]):
                    colon += 1
                if (colon == begin + 1 or statement[colon:colon + 1] != [':']
                        or colon + 1 >= end or statement[colon + 1] == '='):
                    break
                parameter_names.update(range(begin + 1, colon))
                enters_scope[j] = set(statement[begin + 1:colon])

        bound = set()
        for i, token in enumerate(statement):
            bound.update(enters_scope.get(i, ()))
            if i == binding or i in parameter_names:
                continue
            parts = token.split('.')
            if not any(part.lower() in escapes for part in parts):
                continue
            # Qualified names can name the real primitive despite an identically
            # named local variable. Tactic keywords are not term binders either.
            if len(parts) > 1 or token.lower() in tactic_escapes or token not in bound:
                return True
        return False

    # Preserve each existing escape's complete statement, not just its count:
    # removing one assumption must not buy permission to introduce another.
    result = collections.Counter()
    statement = []
    for token in tokens + ['.']:
        statement.append(token)
        if token == '.':
            if is_escape(statement):
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


# This trusted runner receives a JSON list, not shell words or lines. POSIX
# filenames may contain spaces, newlines and glob metacharacters. Running it
# after the command in the same shell also preserves any exported toolchain
# environment the command selected for its added tests.
ADDED_TEST_RUNNER = r'''import json, os, subprocess, sys
with open(sys.argv[1]) as stream:
    names = json.load(stream)
os.unlink(sys.argv[1])
for name in names:
    print("CI: " + name + " (this tree adds it)", flush=True)
    try:
        with open(name, "rb") as stream:
            first = stream.readline(4096)
        shell = "bash" if first.startswith(b"#!") and b"bash" in first else "sh"
        status = subprocess.run(["timeout", os.environ.get("PANTHEON_TEST_TIMEOUT", "600"), shell, name]).returncode
    except OSError as error:
        print("CI: " + name + ": " + str(error), file=sys.stderr, flush=True)
        status = 127
    if status:
        print("CI: " + name + " failed (exit " + str(status) + ")", flush=True)
        sys.exit(status)
'''


if __name__ == '__main__':
    if sys.argv[1] == '--verify':
        try:
            baseline = json.loads(sys.argv[2])
            verify(Path.cwd(), baseline)
            for name in deployment_changes(Path.cwd(), baseline):
                print('CI: this tree changes ' + name + ' (deployment: CI ran the deployed copy; it takes effect once the operator deploys it)', file=sys.stderr)
            print(json.dumps(added_tests(Path.cwd(), baseline)))
        except (ValueError, OSError) as e:
            sys.exit('CI policy: ' + str(e))
    else:
        root = Path(sys.argv[1]).resolve()
        baseline = json.dumps(manifest(root), separators=(',', ':'))
        source = Path(__file__).read_text()
        # The policy check, then the command, then each test the bid adds.
        # A private temporary JSON manifest transports arbitrary filenames;
        # the EXIT trap also removes it when policy or the command fails.
        print('pantheon_added_file=$(mktemp "${TMPDIR:-/tmp}/pantheon-added.XXXXXXXX") || exit 3\n'
              'trap \'rm -f "$pantheon_added_file"\' 0\n'
              'python3 - --verify ' + shlex.quote(baseline) + " > \"$pantheon_added_file\" <<'PANTHEON_CI_POLICY'\n" + source +
              '\nPANTHEON_CI_POLICY\npolicy_status=$?; [ "$policy_status" -eq 0 ] || exit "$policy_status"\n'
              '{\n' + sys.argv[2] + '\n} && python3 -c ' + shlex.quote(ADDED_TEST_RUNNER) + ' "$pantheon_added_file"')
