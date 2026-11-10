#!/bin/sh
# Exercise the actual self-contained command used by both deployments.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
mkdir -p "$t/head/test" "$t/head/deploy"
printf 'p := 1.\n' > "$t/head/main.soma"
printf 'Lemma good : True. Proof. exact I. Qed.\n' > "$t/head/main.proof"
printf '#!/bin/sh\ntest -f main.soma\n' > "$t/head/test/check.sh"
cp "$here/deploy/ci-command.py" "$t/head/deploy/ci-command.py"
python3 "$here/deploy/ci-command.py" "$t/head" 'sh test/check.sh' > "$t/command"
run() { (cd "$t/bid" && sh "$t/command"); }
reset() { rm -rf "$t/bid"; cp -R "$t/head" "$t/bid"; }
refuse() { if run > "$t/output" 2>&1; then echo "FAIL accepted $1"; exit 1; fi; grep -q 'CI policy:' "$t/output"; echo "ok refuses $1"; }
for assumption in 'Lemma hole : False. Admitted.' 'Axiom hole : False.' 'hole : False := unk.'; do
  reset
  case "$assumption" in Lemma*) file=main.proof ;; *) file=main.soma ;; esac
  printf '%s\n' "$assumption" >> "$t/bid/$file"
  refuse "$assumption"
done
reset
printf '#!/bin/sh\nexit 0\n' > "$t/bid/test/check.sh"
refuse 'weakened test'
reset
printf 'exit 0\n' > "$t/bid/deploy/ci-command.py"
printf 'hole := unk.\n' >> "$t/bid/main.soma"
refuse 'replaced policy'
reset
printf 'q := 2. (* Admitted, Axiom and unk in a comment are harmless. *)\n' >> "$t/bid/main.soma"
run
echo 'ok accepts honest change'
# Existing escape hatches do not license a new assumption of the same count.
printf 'old := unk.\n' >> "$t/head/main.soma"
python3 "$here/deploy/ci-command.py" "$t/head" 'sh test/check.sh' > "$t/command"
reset
run
sed 's/old := unk/new := unk/' "$t/bid/main.soma" > "$t/main.soma.new" && mv "$t/main.soma.new" "$t/bid/main.soma"  # not sed -i: BSD's differs
refuse 'traded existing assumption'
# The tests a bid adds run after the command, and a failing one fails CI
# (docs/DOGFOOD-REPORT.md D-1); the command's own failure still fails it.
python3 "$here/deploy/ci-command.py" "$t/head" 'sh test/check.sh' > "$t/command"
reset
printf '#!/bin/sh\necho added-ran\n' > "$t/bid/test/added.sh"
run > "$t/output" 2>&1 || { cat "$t/output"; echo "FAIL a passing added test failed CI"; exit 1; }
grep -q 'added-ran' "$t/output" || { cat "$t/output"; echo "FAIL the added test didn't run"; exit 1; }
echo 'ok runs a test the bid adds'
printf '#!/bin/sh\necho added-failed; exit 3\n' > "$t/bid/test/added2.sh"
if run > "$t/output" 2>&1; then cat "$t/output"; echo "FAIL a failing added test passed CI"; exit 1; fi
grep -q 'test/added2.sh failed (exit 3)' "$t/output" || { cat "$t/output"; echo "FAIL no word of the failing test"; exit 1; }
echo 'ok a failing added test fails CI'
reset
printf '#!/bin/sh\necho never > "$0.ran"\n' > "$t/bid/test/late.sh"
rm "$t/bid/main.soma"; printf 'p := 1.\n' > "$t/bid/main.soma"; rm "$t/bid/test/check.sh"; printf '#!/bin/sh\nexit 4\n' > "$t/bid/test/check.sh"
if run > "$t/output" 2>&1; then echo "FAIL a changed pinned test passed"; exit 1; fi
[ ! -e "$t/bid/test/late.sh.ran" ] || { echo "FAIL an added test ran after the policy refused the tree"; exit 1; }
echo 'ok nothing runs once the policy refuses a tree'
reset
ln -s /etc/passwd "$t/bid/test/link.sh"
run > "$t/output" 2>&1 || { cat "$t/output"; echo "FAIL a symlinked test broke CI"; exit 1; }
! grep -q 'test/link.sh' "$t/output" || { echo "FAIL a symlink ran as a test"; exit 1; }
echo 'ok a symlink in test/ is not run'
reset
printf '#!/bin/bash\n[[ -n x ]] && echo bash-test-ran\n' > "$t/bid/test/bashy.sh"
run > "$t/output" 2>&1 || { cat "$t/output"; echo "FAIL a bash test failed"; exit 1; }
grep -q bash-test-ran "$t/output" || { cat "$t/output"; echo "FAIL the bash test didn't run in bash"; exit 1; }
echo 'ok an added test that asks for bash runs in bash'
# A bid may change the deployment (deploy/, scripts/host.sh, scripts/sandbox.sh):
# CI ran the deployed copies, and says what the tree changes
reset
mkdir -p "$t/bid/scripts"; printf '#!/bin/sh\necho changed\n' > "$t/bid/scripts/host.sh"; printf '# changed\n' >> "$t/bid/deploy/ci-command.py"
run > "$t/output" 2>&1 || { cat "$t/output"; echo "FAIL a deployment change failed CI"; exit 1; }
grep -q 'this tree changes deploy/ci-command.py' "$t/output" && grep -q 'this tree changes scripts/host.sh' "$t/output" \
  || { cat "$t/output"; echo "FAIL CI didn't say what the tree changes of the deployment"; exit 1; }
echo 'ok a bid may change the deployment, and CI says so'
